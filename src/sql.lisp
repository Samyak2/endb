(defpackage :endb/sql
  (:use :cl)
  (:export #:*query-timing* #:make-db #:make-directory-db #:close-db #:begin-write-tx #:commit-write-tx #:execute-sql #:interpret-sql-literal)
  (:import-from :alexandria)
  (:import-from :endb/arrow)
  (:import-from :endb/json)
  (:import-from :endb/sql/expr)
  (:import-from :endb/sql/compiler)
  (:import-from :endb/lib/arrow)
  (:import-from :endb/lib/parser)
  (:import-from :endb/storage/buffer-pool)
  (:import-from :endb/storage/object-store)
  (:import-from :endb/storage/wal)
  (:import-from :trivial-utf-8)
  (:import-from :fset))
(in-package :endb/sql)

(defvar *query-timing* nil)

(defun %replay-log (read-wal)
  (loop with md = (fset:empty-map)
        for (buffer . name) = (multiple-value-bind (buffer name)
                                  (endb/storage/wal:wal-read-next-entry read-wal :skip-if (lambda (x)
                                                                                            (not (alexandria:starts-with-subseq "_log/" x))))
                                (cons buffer name))
        when buffer
          do (setf md (endb/json:json-merge-patch md (endb/json:json-parse buffer)))
        while name
        finally (return md)))

(defun make-db (&key (meta-data (fset:empty-map)) (wal (endb/storage/wal:make-memory-wal)) (object-store (endb/storage/object-store:make-memory-object-store)))
  (let* ((buffer-pool (endb/storage/buffer-pool:make-buffer-pool :object-store object-store)))
    (endb/sql/expr:make-db :wal wal :object-store object-store :buffer-pool buffer-pool :meta-data meta-data)))

(defun make-directory-db (&key (directory "endb_data")
                            (object-store-path (merge-pathnames "object_store" (uiop:ensure-directory-pathname directory)))
                            (wal-file (merge-pathnames "wal.log" (uiop:ensure-directory-pathname directory))))
  (ensure-directories-exist wal-file)
  (let* ((md (with-open-file (read-in wal-file :direction :io
                                               :element-type '(unsigned-byte 8)
                                               :if-exists :overwrite
                                               :if-does-not-exist :create)
               (if (plusp (file-length read-in))
                   (%replay-log (endb/storage/wal:open-tar-wal :stream read-in :direction :input))
                   (fset:empty-map))))
         (write-io (open wal-file :direction :io :element-type '(unsigned-byte 8) :if-exists :overwrite :if-does-not-exist :create))
         (write-wal (endb/storage/wal:open-tar-wal :stream write-io))
         (os (if (or (null object-store-path)
                     (equal (pathname object-store-path) (pathname wal-file)))
                 (endb/storage/object-store:open-tar-object-store :stream (open wal-file :element-type '(unsigned-byte 8) :if-does-not-exist :create))
                 (endb/storage/object-store:make-directory-object-store :path object-store-path))))
    (endb/storage/wal:tar-wal-position-stream-at-end write-io)
    (make-db :wal write-wal :object-store os :meta-data md)))

(defun close-db (db)
  (endb/storage/wal:wal-close (endb/sql/expr:db-wal db))
  (endb/storage/buffer-pool:buffer-pool-close (endb/sql/expr:db-buffer-pool db))
  (endb/storage/object-store:object-store-close (endb/sql/expr:db-object-store db)))

(defun begin-write-tx (db)
  (let* ((bp (endb/storage/buffer-pool:make-writeable-buffer-pool :parent-pool (endb/sql/expr:db-buffer-pool db)))
         (write-db (endb/sql/expr:copy-db db)))
    (setf (endb/sql/expr:db-buffer-pool write-db) bp)
    (setf (endb/sql/expr:db-current-timestamp write-db) (endb/sql/expr:syn-current_timestamp db))
    write-db))

(defun %log-filename (tx-id)
  (format nil "_log/~(~16,'0x~).json" tx-id))

(defun %write-new-buffers (write-db)
  (let ((os (endb/sql/expr:db-object-store write-db))
        (bp (endb/sql/expr:db-buffer-pool write-db))
        (wal (endb/sql/expr:db-wal write-db)))
    (loop for k being the hash-key
            using (hash-value v)
              of (endb/storage/buffer-pool:writeable-buffer-pool-pool bp)
          for buffer = (endb/lib/arrow:write-arrow-arrays-to-ipc-buffer v)
          do (endb/storage/object-store:object-store-put os k buffer)
             (endb/storage/wal:wal-append-entry wal k buffer))))

(defun %execute-constraints (db)
  (let ((ctx (fset:map (:db db))))
    (fset:do-map (k v (endb/sql/expr:constraint-definitions db))
      (when (equal '((nil)) (funcall (endb/sql/compiler:compile-sql ctx v) db (fset:empty-seq)))
        (error 'endb/sql/expr:sql-runtime-error :message (format nil "Constraint failed: ~A" k))))))

(defun commit-write-tx (current-db write-db &key (fsyncp t))
  (let ((current-md (endb/sql/expr:db-meta-data current-db))
        (tx-md (endb/sql/expr:db-meta-data write-db)))
    (if (eq current-md tx-md)
        current-db
        (progn
          (%execute-constraints write-db)
          (let* ((tx-id (1+ (or (fset:lookup tx-md "_last_tx") 0)))
                 (tx-md (fset:with tx-md "_last_tx" tx-id))
                 (md-diff (endb/json:json-diff current-md tx-md))
                 (md-diff-bytes (trivial-utf-8:string-to-utf-8-bytes (endb/json:json-stringify md-diff)))
                 (wal (endb/sql/expr:db-wal write-db)))
            (%write-new-buffers write-db)
            (endb/storage/wal:wal-append-entry wal (%log-filename tx-id) md-diff-bytes)
            (when fsyncp
              (endb/storage/wal:wal-fsync wal))
            (let ((new-db (endb/sql/expr:copy-db current-db))
                  (new-md (endb/json:json-merge-patch current-md md-diff)))
              (setf (endb/sql/expr:db-meta-data new-db) new-md)
              new-db))))))

(defun %execute-sql (db sql parameters manyp)
  (when (and manyp (not (fset:seq? parameters)))
    (error 'endb/sql/expr:sql-runtime-error :message "Many parameters must be a seq"))
  (let* ((ast (endb/lib/parser:parse-sql sql))
         (ctx (fset:map (:db db) (:sql sql)))
         (all-parameters (if manyp
                             (fset:convert 'list parameters)
                             (list parameters)))
         (all-parameters (loop for parameters in all-parameters
                               collect (etypecase parameters
                                         (fset:map parameters)
                                         (fset:seq (fset:convert 'fset:map (loop for x in (fset:convert 'list parameters)
                                                                                 for idx from 0
                                                                                 collect (cons idx x))))
                                         (t (error 'endb/sql/expr:sql-runtime-error :message "Parameters must be seq or a map")))))
         (*print-length* 16)
         (sql-fn (if (eq :multiple-statments (first ast))
                     (let ((asts (second ast)))
                       (if (= 1 (length asts))
                           (endb/sql/compiler:compile-sql ctx (first asts))
                           (lambda (db parameters)
                             (let* ((no-parameters "Multiple statements do not support parameters")
                                    (ctx (fset:with ctx :no-parameters no-parameters)))
                               (if (or (plusp (fset:size parameters)) manyp)
                                   (error 'endb/sql/expr:sql-runtime-error :message no-parameters)
                                   (loop with end-idx = (length asts)
                                         for ast in asts
                                         for idx from 1
                                         for sql-fn = (endb/sql/compiler:compile-sql ctx ast)
                                         if (= end-idx idx)
                                           do (return (funcall sql-fn db parameters))
                                         else
                                           do (funcall sql-fn db parameters)))))))
                     (endb/sql/compiler:compile-sql ctx ast))))
    (loop with final-result = nil
          with final-result-code = nil
          for parameters in all-parameters
          do (multiple-value-bind (result result-code)
                 (funcall sql-fn db parameters)
               (setf final-result result)
               (if (numberp result-code)
                   (setf final-result-code (+ result-code (or final-result-code 0)))
                   (setf final-result-code result-code)))
          finally (return (values final-result final-result-code)))))

(defun execute-sql (db sql &optional (parameters (fset:empty-seq)) manyp)
  (handler-case
      (if *query-timing*
          (time (%execute-sql db sql parameters manyp))
          (%execute-sql db sql parameters manyp))
    #+sbcl (sb-pcl::effective-method-condition (e)
             (error 'endb/sql/expr:sql-runtime-error
                    :message (format nil "Invalid argument types: ~A(~{~A~^, ~})"
                                     (ppcre:regex-replace "^SQL-(UNARY)?"
                                                          (symbol-name (sb-pcl::generic-function-name
                                                                        (sb-pcl::effective-method-condition-generic-function e)))
                                                          "")
                                     (loop for arg in (sb-pcl::effective-method-condition-args e)
                                           collect (if (stringp arg)
                                                       (prin1-to-string arg)
                                                       (endb/sql/expr:sql-cast arg :varchar))))))))

(defun %interpret-sql-literal (ast)
  (cond
    ((or (stringp ast)
         (numberp ast)
         (vectorp ast))
     ast)
    ((eq :true ast) t)
    ((eq :false ast) nil)
    ((eq :null ast) :null)
    ((and (listp ast)
          (= 2 (length ast)))
     (case (first ast)
       (:- (if (numberp (second ast))
               (- (second ast))
               (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal")))
       (:date (endb/sql/expr:sql-date (second ast)))
       (:time (endb/sql/expr:sql-time (second ast)))
       (:timestamp (endb/sql/expr:sql-datetime (second ast)))
       (:duration (endb/sql/expr:sql-duration (second ast)))
       (:blob (endb/sql/expr:sql-unhex (second ast)))
       (:array (fset:convert 'fset:seq (mapcar #'%interpret-sql-literal (second ast))))
       (:object (reduce
                 (lambda (acc kv)
                   (let ((k (first kv)))
                     (fset:with acc (if (stringp k)
                                        k
                                        (symbol-name k))
                                (%interpret-sql-literal (second kv)))))
                 (second ast)
                 :initial-value (fset:empty-map)))
       (t (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal"))))
    ((and (listp ast)
          (eq :interval (first ast))
          (<= 2 (length (rest ast)) 3))
     (apply #'endb/sql/expr:sql-interval (rest ast)))
    (t (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal"))))

(defun interpret-sql-literal (src)
  (let* ((select-list (handler-case
                          (cadr (endb/lib/parser:parse-sql (format nil "SELECT ~A" src)))
                        (endb/lib/parser:sql-parse-error (e)
                          (declare (ignore e)))))
         (ast (car select-list))
         (literal (if (or (not (= 1 (length select-list)))
                          (not (= 1 (length ast))))
                      :error
                      (handler-case
                          (%interpret-sql-literal (car ast))
                        (endb/sql/expr:sql-runtime-error (e)
                          (declare (ignore e))
                          :error)))))
    (if (eq :error literal)
        (error 'endb/sql/expr:sql-runtime-error
               :message (format nil "Invalid literal: ~A" src))
        literal)))

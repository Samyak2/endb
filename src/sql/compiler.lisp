(defpackage :endb/sql/compiler
  (:use :cl)
  (:import-from :endb/sql/expr)
  (:export #:compile-sql))
(in-package :endb/sql/compiler)

(defgeneric sql->cl (ctx type &rest args))

(defun %compiler-symbol (x)
  (intern (if (symbolp x)
              (symbol-name x)
              x)
          :endb/sql/compiler))

(defun %anonymous-column-name (idx)
  (%compiler-symbol (concatenate 'string "column" (princ-to-string idx))))

(defun %unqualified-column-name (column)
  (let* ((column-str (symbol-name column))
         (idx (position #\. column-str)))
    (if idx
        (%compiler-symbol (subseq column-str (1+ idx)))
        column)))

(defun %qualified-column-name (table-alias column)
  (%compiler-symbol (concatenate 'string (symbol-name table-alias) "." (symbol-name column))))

(defun %select-projection (select-list select-star-projection)
  (loop for idx from 1
        for (expr . alias) in select-list
        append (cond
                 ((eq :star expr) select-star-projection)
                 (alias (list alias))
                 ((symbolp expr) (list (%unqualified-column-name expr)))
                 (t (list (%anonymous-column-name idx))))))

(defun %base-table (ctx table)
  (let ((db-table (gethash (symbol-name table) (cdr (assoc :db ctx)))))
    (values `(endb/sql/expr:base-table-rows (gethash ,(symbol-name table) ,(cdr (assoc :db-sym ctx))))
            (mapcar #'%compiler-symbol (endb/sql/expr:base-table-columns db-table)))))

(defun %wrap-with-order-by-and-limit (src order-by limit)
  (let* ((src (if order-by
                  `(endb/sql/expr::%sql-order-by ,src ',order-by)
                  src))
         (src (if limit
                  `(endb/sql/expr::%sql-limit ,src ',limit)
                  src)))
    src))

(defun %and-clauses (expr)
  (if (and (listp expr)
           (eq :and (first expr)))
      (append (%and-clauses (second expr))
              (%and-clauses (third expr)))
      (list expr)))

(defstruct from-table
  table-src
  local-vars
  qualified-projection)

(defvar *predicate-pushdown-ops*
  '(endb/sql/expr:sql-=
    endb/sql/expr:sql-is
    endb/sql/expr:sql-in
    endb/sql/expr:sql-<
    endb/sql/expr:sql->
    endb/sql/expr:sql-<=
    endb/sql/expr:sql->=))

(defun %binary-predicate-p (x)
  (and (listp x)
       (= 3 (length x))))

(defun %literalp (x)
  (and (atom x)
       (not (symbolp x))))

(defun %literal-list-p (xs)
  (and (listp xs)
       (equal 'list (first xs))
       (every #'%literalp (rest xs))))

(defun %scan-predicate-p (local-vars clause)
  (when (%binary-predicate-p clause)
    (destructuring-bind (op lhs rhs)
        clause
      (let ((lhs-var-p (member lhs local-vars))
            (rhs-var-p (member rhs local-vars)))
        (and (member op *predicate-pushdown-ops* :test 'equal)
             (or (and lhs-var-p (%literalp rhs))
                 (and lhs-var-p (%literal-list-p rhs))
                 (and (%literalp lhs) rhs-var-p)
                 (and lhs-var-p rhs-var-p)))))))

(defun %equi-join-predicate-p (vars clause)
  (when (%binary-predicate-p clause)
    (destructuring-bind (op lhs rhs)
        clause
      (and (equal 'endb/sql/expr:sql-= op)
           (member lhs vars)
           (member rhs vars)))))

(defun %pushdown-predicate-p (vars clause)
  (when (%binary-predicate-p clause)
    (destructuring-bind (op lhs rhs)
        clause
      (and (member op *predicate-pushdown-ops* :test 'equal)
           (or (member lhs vars)
               (%literalp lhs))
           (or (member rhs vars)
               (%literalp rhs))))))

(defmethod sql->cl (ctx (type (eql :select)) &rest args)
  (destructuring-bind (select-list &key distinct (from '(((:values ((:null))) . #:dual))) (where :true)
                                     (group-by () group-by-p) (having :true havingp)
                                     order-by limit)
      args
    (labels ((join->cl (ctx local-vars equi-join-clauses table-src)
               (multiple-value-bind (in-vars out-vars)
                   (loop for (nil lhs rhs) in equi-join-clauses
                         if (member lhs local-vars)
                           collect lhs into out-vars
                         else
                           collect lhs into in-vars
                         if (member rhs local-vars)
                           collect rhs into out-vars
                         else
                           collect rhs into in-vars
                         finally
                            (return (values in-vars out-vars)))
                 (let ((index-table-sym (gensym))
                       (index-key-sym (gensym)))
                   `(let ((,index-table-sym (or (gethash ',index-key-sym ,(cdr (assoc :index-sym ctx)))
                                                (let ((,index-table-sym (setf (gethash ',index-key-sym ,(cdr (assoc :index-sym ctx)))
                                                                              (make-hash-table :test 'equal))))
                                                  (loop for ,local-vars
                                                          in ,table-src
                                                        do (push (list ,@local-vars) (gethash (list ,@out-vars) ,index-table-sym)))
                                                  ,index-table-sym))))
                      (gethash (list ,@in-vars) ,index-table-sym)))))
             (from->cl (ctx vars from-tables where-clauses selected-src)
               (with-slots (table-src local-vars)
                   (first from-tables)
                 (let* ((vars (append local-vars vars)))
                   (multiple-value-bind (scan-clauses equi-join-clauses pushdown-clauses)
                       (loop for c in where-clauses
                             if (%scan-predicate-p local-vars c)
                               collect c into scan-clauses
                             else if (%equi-join-predicate-p vars c)
                                    collect c into equi-join-clauses
                             else if (%pushdown-predicate-p vars c)
                                    collect c into pushdown-clauses
                             finally
                                (return (values scan-clauses equi-join-clauses pushdown-clauses)))
                     (let* ((new-where-clauses (append scan-clauses equi-join-clauses pushdown-clauses))
                            (where-clauses (set-difference where-clauses new-where-clauses)))
                       `(loop for ,local-vars
                                in ,(let ((table-src (if scan-clauses
                                                         `(loop for ,local-vars
                                                                  in ,table-src
                                                                ,@(loop for clause in scan-clauses append `(when (eq t ,clause)))
                                                                collect (list ,@local-vars))
                                                         table-src)))
                                      (if equi-join-clauses
                                          (join->cl ctx local-vars equi-join-clauses table-src)
                                          table-src))
                              ,@(loop for clause in pushdown-clauses append `(when (eq t ,clause)))
                              ,@(if (rest from-tables)
                                    `(nconc ,(from->cl ctx vars (rest from-tables) where-clauses selected-src))
                                    `(,@(loop for clause in where-clauses append `(when (eq t ,clause)))
                                      collect (list ,@selected-src)))))))))
             (group-by->cl (ctx from-tables where-clauses selected-src)
               (let* ((aggregate-table (cdr (assoc :aggregate-table ctx)))
                      (having-src (ast->cl ctx having))
                      (group-by-projection (loop for g in group-by
                                                 collect (ast->cl ctx g)))
                      (group-by-exprs-projection (loop for k being the hash-key of aggregate-table
                                                       collect k))
                      (group-by-exprs (loop for v being the hash-value of aggregate-table
                                            collect v))
                      (group-by-selected-src (append group-by-projection group-by-exprs))
                      (from-src (from->cl ctx () from-tables where-clauses group-by-selected-src))
                      (group-by-src `(endb/sql/expr::%sql-group-by ,from-src ,(length group-by-projection) ,(length group-by-exprs))))
                 `(loop for ,group-by-projection being the hash-key
                          using (hash-value ,group-by-exprs-projection)
                            of ,group-by-src
                        when (eq t ,having-src)
                          collect (list ,@selected-src))))
             (select->cl (ctx from-ast from-tables)
               (destructuring-bind (table-or-subquery . table-alias)
                   (first from-ast)
                 (multiple-value-bind (table-src projection)
                     (if (symbolp table-or-subquery)
                         (%base-table ctx table-or-subquery)
                         (ast->cl ctx table-or-subquery))
                   (let* ((qualified-projection (loop for column in projection
                                                      collect (%qualified-column-name table-alias column)))
                          (env-extension (loop for column in projection
                                               for qualified-column = (%qualified-column-name table-alias column)
                                               for column-sym = (gensym (concatenate 'string (symbol-name qualified-column) "__"))
                                               append (list (cons column column-sym) (cons qualified-column column-sym))))
                          (ctx (append env-extension ctx))
                          (from-table (make-from-table :table-src table-src
                                                       :local-vars (remove-duplicates (mapcar #'cdr env-extension))
                                                       :qualified-projection qualified-projection))
                          (from-tables (append from-tables (list from-table))))
                     (if (rest from-ast)
                         (select->cl ctx (rest from-ast) from-tables)
                         (let* ((aggregate-table (make-hash-table))
                                (ctx (cons (cons :aggregate-table aggregate-table) ctx))
                                (full-projection (mapcan #'from-table-qualified-projection from-tables))
                                (selected-src (loop for (expr) in select-list
                                                    append (if (eq :star expr)
                                                               (loop for p in full-projection
                                                                     collect (ast->cl ctx p))
                                                               (list (ast->cl ctx expr)))))
                                (where-clauses (loop for clause in (%and-clauses where)
                                                     collect (ast->cl ctx clause)))
                                (from-tables (sort from-tables #'> :key
                                                   (lambda (x)
                                                     (loop for clause in where-clauses
                                                           count (%scan-predicate-p (from-table-local-vars x) clause)))))
                                (group-by-needed-p (or group-by-p havingp (plusp (hash-table-count aggregate-table)))))
                           (values
                            (if group-by-needed-p
                                (group-by->cl ctx from-tables where-clauses selected-src)
                                (from->cl ctx () from-tables where-clauses selected-src))
                            full-projection))))))))
      (multiple-value-bind (src full-projection)
          (select->cl ctx from ())
        (let* ((src (if distinct
                        `(endb/sql/expr::%sql-distinct ,src)
                        src))
               (src (%wrap-with-order-by-and-limit src order-by limit))
               (select-star-projection (mapcar #'%unqualified-column-name full-projection)))
          (values src (%select-projection select-list select-star-projection)))))))

(defun %values-projection (arity)
  (loop for idx from 1 upto arity
        collect (%anonymous-column-name idx)))

(defmethod sql->cl (ctx (type (eql :values)) &rest args)
  (destructuring-bind (values-list &key order-by limit)
      args
    (values (%wrap-with-order-by-and-limit (ast->cl ctx values-list) order-by limit)
            (%values-projection (length (first values-list))))))

(defmethod sql->cl (ctx (type (eql :union)) &rest args)
  (destructuring-bind (lhs rhs &key order-by limit)
      args
    (multiple-value-bind (lhs-src columns)
        (ast->cl ctx lhs)
      (values (%wrap-with-order-by-and-limit `(endb/sql/expr:sql-union ,lhs-src ,(ast->cl ctx rhs)) order-by limit) columns))))

(defmethod sql->cl (ctx (type (eql :union-all)) &rest args)
  (destructuring-bind (lhs rhs &key order-by limit)
      args
    (multiple-value-bind (lhs-src projection)
        (ast->cl ctx lhs)
      (values (%wrap-with-order-by-and-limit `(endb/sql/expr:sql-union-all ,lhs-src ,(ast->cl ctx rhs)) order-by limit) projection))))

(defmethod sql->cl (ctx (type (eql :except)) &rest args)
  (destructuring-bind (lhs rhs &key order-by limit)
      args
    (multiple-value-bind (lhs-src projection)
        (ast->cl ctx lhs)
      (values (%wrap-with-order-by-and-limit `(endb/sql/expr:sql-except ,lhs-src ,(ast->cl ctx rhs)) order-by limit) projection))))

(defmethod sql->cl (ctx (type (eql :intersect)) &rest args)
  (destructuring-bind (lhs rhs &key order-by limit)
      args
    (multiple-value-bind (lhs-src projection)
        (ast->cl ctx lhs)
      (values (%wrap-with-order-by-and-limit `(endb/sql/expr:sql-intersect ,lhs-src ,(ast->cl ctx rhs)) order-by limit) projection))))

(defmethod sql->cl (ctx (type (eql :create-table)) &rest args)
  (destructuring-bind (table-name column-names)
      args
    `(endb/sql/expr:sql-create-table ,(cdr (assoc :db-sym ctx)) ,(symbol-name table-name) ',(mapcar #'symbol-name column-names))))

(defmethod sql->cl (ctx (type (eql :create-index)) &rest args)
  (declare (ignore args))
  `(endb/sql/expr:sql-create-index ,(cdr (assoc :db-sym ctx))))

(defmethod sql->cl (ctx (type (eql :insert)) &rest args)
  (destructuring-bind (table-name values &key column-names)
      args
    `(endb/sql/expr:sql-insert ,(cdr (assoc :db-sym ctx)) ,(symbol-name table-name) ,(ast->cl ctx values)
                               :column-names ',(mapcar #'symbol-name column-names))))

(defmethod sql->cl (ctx (type (eql :subquery)) &rest args)
  (destructuring-bind (query)
      args
    (ast->cl ctx query)))

(defun %find-sql-expr-symbol (fn)
  (find-symbol (string-upcase (concatenate 'string "sql-" (symbol-name fn))) :endb/sql/expr))

(defmethod sql->cl (ctx (type (eql :function)) &rest args)
  (destructuring-bind (fn args)
      args
    (let ((fn-sym (%find-sql-expr-symbol fn)))
      (assert fn-sym nil (format nil "Unknown built-in function: ~A" fn))
      `(,fn-sym ,@(loop for ast in args
                        collect (ast->cl ctx ast))))))

(defmethod sql->cl (ctx (type (eql :aggregate-function)) &rest args)
  (destructuring-bind (fn args &key distinct)
      args
    (let ((aggregate-table (cdr (assoc :aggregate-table ctx)))
          (fn-sym (%find-sql-expr-symbol fn))
          (aggregate-sym (gensym)))
      (assert fn-sym nil (format nil "Unknown aggregate function: ~A" fn))
      (assert (<= (length args) 1) nil (format nil "Aggregates require max 1 argument, got: ~D" (length args)))
      (setf (gethash aggregate-sym aggregate-table) (ast->cl ctx (first args)))
      `(,fn-sym ,aggregate-sym :distinct ,distinct))))

(defmethod sql->cl (ctx (type (eql :case)) &rest args)
  (destructuring-bind (cases-or-expr &optional cases)
      args
    (let ((expr-sym (gensym)))
      `(let ((,expr-sym ,(if cases
                             (ast->cl ctx cases-or-expr)
                             t)))
         (cond
           ,@(loop for (test then) in (or cases cases-or-expr)
                   collect (list (if (eq :else test)
                                     t
                                     `(eq t (endb/sql/expr:sql-= ,expr-sym ,(ast->cl ctx test))))
                                 (ast->cl ctx then))))))))

(defmethod sql->cl (ctx fn &rest args)
  (sql->cl ctx :function fn args))

(defun %ast-function-call-p (ast)
  (and (listp ast)
       (keywordp (first ast))
       (not (member (first ast) '(:null :true :false)))))

(defun ast->cl (ctx ast)
  (cond
    ((eq :true ast) t)
    ((eq :false ast) nil)
    ((%ast-function-call-p ast)
     (apply #'sql->cl ctx ast))
    ((listp ast)
     (cons 'list (loop for ast in ast
                       collect (ast->cl ctx ast))))
    ((and (symbolp ast)
          (not (keywordp ast)))
     (cdr (assoc (%compiler-symbol (symbol-name ast)) ctx)))
    (t ast)))

(defun compile-sql (ctx ast)
  (let* ((db-sym (gensym))
         (index-sym (gensym))
         (ctx (cons (cons :db-sym db-sym) ctx))
         (ctx (cons (cons :index-sym index-sym) ctx)))
    (multiple-value-bind (src projection)
        (ast->cl ctx ast)
      (eval `(lambda (,db-sym)
               (declare (optimize (speed 3) (safety 0) (debug 0)))
               (declare (ignorable ,db-sym))
               (let ((,index-sym (make-hash-table :test 'equal)))
                 (declare (ignorable ,index-sym))
                 ,(if projection
                      `(values ,src ,(cons 'list (mapcar #'symbol-name projection)))
                      src)))))))

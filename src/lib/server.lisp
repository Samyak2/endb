(defpackage :endb/lib/server
  (:use :cl)
  (:export #:start-server)
  (:import-from :cffi)
  (:import-from :endb/json)
  (:import-from :endb/lib)
  (:import-from :uiop))
(in-package :endb/lib/server)

(cffi:defcfun "endb_start_server" :void
  (on-init :pointer)
  (on-query :pointer))

(defvar *start-server-on-init*)

(cffi:defcallback start-server-on-init :void
    ((config-json :string))
  (funcall *start-server-on-init* (endb/json:json-parse config-json)))

(defvar *start-server-on-query*)

(cffi:defcallback start-server-on-query :void
    ((method :string)
     (media-type :string)
     (q :string)
     (p :string)
     (m :string)
     (on-response :pointer))
  (funcall *start-server-on-query* method media-type q p m (lambda (status-code content-type body)
                                                             (cffi:foreign-funcall-pointer on-response () :short status-code :string content-type :string body :void))))

(defun start-server (on-init on-query)
  (endb/lib:init-lib)
  (let ((*start-server-on-init* on-init))
    (setf *start-server-on-query* on-query)
    (endb-start-server (cffi:callback start-server-on-init) (cffi:callback start-server-on-query))))
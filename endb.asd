(defsystem "endb"
  :version "0.1.0"
  :author "Håkan Råberg <hakan.raberg@gmail.com>, Steven Deobald <steven@deobald.ca>"
  :license "AGPLv3"
  :homepage "https://www.endatabas.com/"
  :class :package-inferred-system
  :depends-on ("endb/core")
  :description "Endatabas"
  :pathname "src"
  :build-operation "program-op"
  :build-pathname "../endb"
  :entry-point "endb/core:main"
  :in-order-to ((test-op (test-op "endb-test"))))

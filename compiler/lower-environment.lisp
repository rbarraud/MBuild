;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Lower non-local lexical variable accesses so they refer directly
;;;; to environment objects.
;;;; This is done in two passes.
;;;; Pass 1 discovers escaping variables & assigns them slots
;;;; in their environment vector. Determines the extent of every lambda.
;;;; Pass 2 links each environment vector together and actually
;;;; rewrites the code.
;;;; Vectors are created at LAMBDA and TAGBODY nodes.

(in-package :sys.c)

(defvar *environment-chain*)
(defvar *environment-layout*)
(defvar *environment-layout-dx*)
(defvar *active-environment-vector*)
(defvar *allow-dx-environment*)
(defvar *environment-allocation-mode* nil)
(defvar *free-variables*)

(defun lower-environment (lambda)
  (let ((*environment-layout* (make-hash-table))
        (*environment-layout-dx* (make-hash-table))
        (*allow-dx-environment* 't))
    (compute-environment-layout lambda)
    (let ((*free-variables* (compute-free-variable-sets lambda))
          (*environment* '()))
      (lower-env-form lambda))))

(defun quoted-form-p (form)
  (typep form 'ast-quote))

(defun compute-environment-layout (form)
  (etypecase form
    (cons (ecase (first form)
	    ((block)
             (compute-block-environment-layout form))
	    ((go) nil)
	    ((let)
             (compute-let-environment-layout form))
	    ((multiple-value-call)
             (mapc #'compute-environment-layout (rest form)))
	    ((return-from)
             (mapc #'compute-environment-layout (rest form)))
	    ((tagbody)
             (compute-tagbody-environment-layout form))
	    ((the)
             (compute-environment-layout (third form)))
	    ((unwind-protect)
             (compute-environment-layout (second form))
             (cond ((lambda-information-p (third form))
                    (unless (getf (lambda-information-plist (third form)) 'extent)
                        (setf (getf (lambda-information-plist (third form)) 'extent) :dynamic))
                    (compute-lambda-environment-layout (third form)))
                   (t (compute-environment-layout (third form)))))
	    ((sys.int::%jump-table)
             (mapc #'compute-environment-layout (rest form)))))
    (ast-function nil)
    (ast-if
     (compute-environment-layout (test form))
     (compute-environment-layout (if-then form))
     (compute-environment-layout (if-else form)))
    (ast-multiple-value-bind
     (compute-mvb-environment-layout form))
    (ast-multiple-value-prog1
     (compute-environment-layout (value-form form))
     (compute-environment-layout (body form)))
    (ast-progn
     (mapc #'compute-environment-layout (forms form)))
    (ast-quote nil)
    (ast-setq
     (compute-environment-layout (value form)))
    (ast-call (cond ((and (eql (name form) 'funcall)
                          (lambda-information-p (first (arguments form))))
                     (unless (getf (lambda-information-plist (first (arguments form))) 'extent)
                       (setf (getf (lambda-information-plist (first (arguments form))) 'extent) :dynamic))
                     (compute-lambda-environment-layout (first (arguments form)))
                     (mapc #'compute-environment-layout (rest (arguments form))))
                    (t (mapc #'compute-environment-layout (arguments form)))))
    (lexical-variable nil)
    (lambda-information
     (setf (getf (lambda-information-plist form) 'dynamic-extent) :indefinite)
     (compute-lambda-environment-layout form))))

(defun maybe-add-environment-variable (variable)
  (when (and (not (symbolp variable))
             (not (localp variable)))
    (push variable (gethash *active-environment-vector* *environment-layout*))))

(defun finalize-environment-layout (env)
  ;; Inner environments must be DX, and every variable in this environment
  ;; must only be accessed by DX lambdas.
  (when (and *allow-dx-environment*
             (every (lambda (var)
                      (every (lambda (l)
                               (or (eql (lexical-variable-definition-point var) l)
                                   (eql (getf (lambda-information-plist l) 'extent) :dynamic)
                                   (getf (lambda-information-plist l) 'declared-dynamic-extent)))
                             (lexical-variable-used-in var)))
                    (gethash env *environment-layout*)))
    (setf (gethash env *environment-layout-dx*) t)
    t))

(defun compute-lambda-environment-layout (lambda)
  (let ((env-is-dx nil))
    (let ((*active-environment-vector* lambda)
          (*allow-dx-environment* t))
      (assert (null (lambda-information-environment-arg lambda)))
      ;; Special variables are not supported here, nor are keywords or non-trivial &OPTIONAL init-forms.
      (assert (every (lambda (arg)
                       (lexical-variable-p arg))
                     (lambda-information-required-args lambda)))
      (assert (every (lambda (arg)
                       (and (lexical-variable-p (first arg))
                            (quoted-form-p (second arg))
                            (or (null (third arg))
                                (lexical-variable-p (first arg)))))
                     (lambda-information-optional-args lambda)))
      (assert (or (null (lambda-information-rest-arg lambda))
                  (lexical-variable-p (lambda-information-rest-arg lambda))))
      (assert (not (lambda-information-enable-keys lambda)))
      (dolist (arg (lambda-information-required-args lambda))
        (maybe-add-environment-variable arg))
      (dolist (arg (lambda-information-optional-args lambda))
        (maybe-add-environment-variable (first arg))
        (when (third arg)
          (maybe-add-environment-variable (third arg))))
      (when (lambda-information-rest-arg lambda)
        (maybe-add-environment-variable (lambda-information-rest-arg lambda)))
      (compute-environment-layout (lambda-information-body lambda))
      (setf env-is-dx (finalize-environment-layout lambda)))
    (unless env-is-dx
      (setf *allow-dx-environment* nil))))

(defun compute-tagbody-environment-layout (form)
  "TAGBODY defines a single variable in the enclosing environment and each group
of statements opens a new contour."
  (maybe-add-environment-variable (second form))
  (let ((env-is-dx t))
    (let ((*active-environment-vector* (second form))
          (*allow-dx-environment* t))
      (dolist (stmt (cddr form))
        (cond ((go-tag-p stmt)
               (unless (finalize-environment-layout *active-environment-vector*)
                 (setf env-is-dx nil))
               (setf *active-environment-vector* stmt
                     *allow-dx-environment* t))
              (t (compute-environment-layout stmt))))
      (unless (finalize-environment-layout *active-environment-vector*)
        (setf env-is-dx nil)))
    (unless env-is-dx
      (setf *allow-dx-environment* nil))))

(defun compute-block-environment-layout (form)
  "BLOCK defines one variable."
  (maybe-add-environment-variable (second form))
  (mapc #'compute-environment-layout (cddr form)))

(defun compute-let-environment-layout (form)
  (dolist (binding (second form))
    (maybe-add-environment-variable (first binding))
    (compute-environment-layout (second binding)))
  (mapc #'compute-environment-layout (cddr form)))

(defun compute-mvb-environment-layout (form)
  (dolist (binding (bindings form))
    (maybe-add-environment-variable binding))
  (compute-environment-layout (value-form form))
  (compute-environment-layout (body form)))

(defun compute-free-variable-sets (lambda)
  (let ((*free-variables* (make-hash-table)))
    (compute-free-variable-sets-1 lambda)
    *free-variables*))

(defun compute-free-variable-sets-1 (form)
  (flet ((process-progn (forms)
           (reduce 'union (mapcar #'compute-free-variable-sets-1 forms) :initial-value '())))
    (etypecase form
      (cons (ecase (first form)
              ((block)
               (remove (second form) (process-progn (cddr form))))
              ((go)
               (compute-free-variable-sets-1 (third form)))
              ((let)
               (let ((vars (union (process-progn (mapcar #'second (second form)))
                                  (process-progn (cddr form))))
                     (defs (mapcar #'first (second form))))
                 (set-difference vars defs)))
              ((multiple-value-call)
               (process-progn (cdr form)))
              ((return-from)
               (union (compute-free-variable-sets-1 (third form))
                      (compute-free-variable-sets-1 (fourth form))))
              ((tagbody)
               (remove (second form) (process-progn (remove-if #'go-tag-p (cddr form)))))
              ((the)
               (compute-free-variable-sets-1 (third form)))
              ((unwind-protect)
               (process-progn (cdr form)))
              ((sys.int::%jump-table)
               (process-progn (cdr form)))))
      (ast-function '())
      (ast-if
       (union (compute-free-variable-sets-1 (test form))
              (union (compute-free-variable-sets-1 (if-then form))
                     (compute-free-variable-sets-1 (if-else form)))))
      (ast-multiple-value-bind
       (let ((vars (union (compute-free-variable-sets-1 (value-form form))
                          (compute-free-variable-sets-1 (body form))))
             (defs (bindings form)))
         (set-difference vars defs)))
      (ast-multiple-value-prog1
       (union (compute-free-variable-sets-1 (value-form form))
                          (compute-free-variable-sets-1 (body form))))
      (ast-progn
       (process-progn (forms form)))
      (ast-quote '())
      (ast-setq
       (union (list (setq-variable form))
              (compute-free-variable-sets-1 (value form))))
      (ast-call
       (process-progn (arguments form)))
      (lexical-variable (list form))
      (lambda-information
       (let* ((initforms (append (mapcar #'second (lambda-information-optional-args form))
                                 (mapcar #'second (lambda-information-key-args form))))
              (defs (append (lambda-information-required-args form)
                            (mapcar #'first (lambda-information-optional-args form))
                            (mapcar #'third (lambda-information-optional-args form))
                            (mapcar #'second (mapcar #'first (lambda-information-key-args form)))
                            (mapcar #'third (lambda-information-key-args form))
                            (when (lambda-information-rest-arg form)
                              (list (lambda-information-rest-arg form)))
                            (when (lambda-information-environment-arg form)
                              (list (lambda-information-environment-arg form)))))
              (vars (set-difference (union (process-progn initforms)
                                           (compute-free-variable-sets-1 (lambda-information-body form)))
                                    defs)))
         (setf (gethash form *free-variables*) vars)
         vars)))))

(defun lower-env-form (form)
  (etypecase form
    (cons (ecase (first form)
	    ((block) (le-block form))
	    ((go) (le-go form))
	    ((let) (le-let form))
	    ((multiple-value-call) (le-form*-cdr form))
	    ((return-from) (le-return-from form))
	    ((tagbody) (le-tagbody form))
	    ((the) (le-the form))
	    ((unwind-protect) (le-form*-cdr form))
	    ((sys.int::%jump-table) (le-form*-cdr form))))
    (ast-function form)
    (ast-if
     (le-if form))
    (ast-multiple-value-bind
     (le-multiple-value-bind form))
    (ast-multiple-value-prog1
     (make-instance 'ast-multiple-value-prog1
                    :value-form (lower-env-form (value-form form))
                    :body (lower-env-form (body form))))
    (ast-progn
     (make-instance 'ast-progn
                    :forms (mapcar #'lower-env-form (forms form))))
    (ast-quote form)
    (ast-setq (le-setq form))
    (ast-call
     (make-instance 'ast-call
                    :name (name form)
                    :arguments (mapcar #'lower-env-form (arguments form))))
    (lexical-variable (le-variable form))
    (lambda-information
     (cond ((or (not *environment-chain*)
                (endp (gethash form *free-variables*)))
            (let ((*environment* '()))
              (le-lambda form)))
           ((getf (lambda-information-plist form) 'declared-dynamic-extent)
            (make-instance 'ast-call
                           :name 'sys.c::make-dx-closure
                           :arguments (list (le-lambda form)
                                            (second (first *environment-chain*)))))
           (*environment-allocation-mode*
            (make-instance 'ast-call
                           :name 'sys.int::make-closure
                           :arguments (list (le-lambda form)
                                            (second (first *environment-chain*))
                                            (make-instance 'ast-quote :value *environment-allocation-mode*))))
           (t (make-instance 'ast-call
                             :name 'sys.int::make-closure
                             :arguments (list (le-lambda form)
                                              (second (first *environment-chain*)))))))))

(defvar *environment-chain* nil
  "The directly accessible environment vectors in this function.")

(defun compute-environment-layout-debug-info ()
  (when *environment*
    (list (second (first *environment-chain*))
          (mapcar (lambda (env)
                    (mapcar (lambda (x)
                              (if (or (tagbody-information-p x)
                                      (block-information-p x))
                                  nil
                                  (lexical-variable-name x)))
                            (gethash env *environment-layout*)))
                  *environment*))))

(defun generate-make-environment (lambda size)
  (cond ((gethash lambda *environment-layout-dx*)
         ;; DX allocation.
         (make-instance 'ast-call
                        :name 'sys.c::make-dx-simple-vector
                        :arguments (list (make-instance 'ast-quote :value size))))
        (*environment-allocation-mode*
         ;; Allocation in an explicit area.
         (make-instance 'ast-call
                        :name 'sys.int::make-simple-vector
                        :arguments (list (make-instance 'ast-quote :value size)
                                         (make-instance 'ast-quote :value *environment-allocation-mode*))))
        ;; General allocation.
        (t (make-instance 'ast-call
                          :name 'sys.int::make-simple-vector
                          :arguments (list (make-instance 'ast-quote :value size))))))

(defun le-lambda (lambda)
  (let ((*environment-chain* '())
        (*environment* *environment*)
        (local-env (gethash lambda *environment-layout*))
        (*current-lambda* lambda)
        (*environment-allocation-mode* (let* ((declares (getf (lambda-information-plist lambda) :declares))
                                              (mode (assoc 'sys.c::closure-allocation declares)))
                                         (if (and mode (cdr mode))
                                             (second mode)
                                             *environment-allocation-mode*))))
    (when *environment*
      ;; The entry environment vector.
      (let ((env (make-instance 'lexical-variable
                                :name (gensym "Environment")
                                :definition-point lambda)))
        (setf (lambda-information-environment-arg lambda) env)
        (push (list (first *environment*) env) *environment-chain*)))
    (cond ((not (endp local-env))
           ;; Environment is present, rewrite body with a new vector.
           (let ((new-env (make-instance 'lexical-variable
                                         :name (gensym "Environment")
                                         :definition-point lambda)))
             (push (list lambda new-env) *environment-chain*)
             (push lambda *environment*)
             (setf (lambda-information-environment-layout lambda) (compute-environment-layout-debug-info))
             (setf (lambda-information-body lambda)
                   `(let ((,new-env ,(generate-make-environment lambda (1+ (length local-env)))))
                      ,@(when (rest *environment-chain*)
                          (list (make-instance 'ast-call
                                               :name '(setf sys.int::%object-ref-t)
                                               :arguments (list (second (second *environment-chain*))
                                                                new-env
                                                                (make-instance 'ast-quote :value '0)))))
                      ,@(mapcar (lambda (arg)
                                  (make-instance 'ast-call
                                                 :name '(setf sys.int::%object-ref-t)
                                                 :arguments (list arg
                                                                  new-env
                                                                  (make-instance 'ast-quote
                                                                                 :value (1+ (position arg local-env))))))
                                (remove-if #'localp (lambda-information-required-args lambda)))
                      ,@(mapcar (lambda (arg)
                                  (make-instance 'ast-call
                                                 :name '(setf sys.int::%object-ref-t)
                                                 :arguments (list (first arg)
                                                                  new-env
                                                                  (make-instance 'ast-quote
                                                                                 :value (1+ (position (first arg) local-env))))))
                                (remove-if #'localp (lambda-information-optional-args lambda)
                                           :key #'first))
                      ,@(mapcar (lambda (arg)
                                  (make-instance 'ast-call
                                                 :name '(setf sys.int::%object-ref-t)
                                                 :arguments (list (third arg)
                                                                  new-env
                                                                  (make-instance 'ast-quote
                                                                                 :value (1+ (position (third arg) local-env))))))
                                (remove-if #'(lambda (x) (or (null x) (localp x)))
                                           (lambda-information-optional-args lambda)
                                           :key #'third))
                      ,@(when (and (lambda-information-rest-arg lambda)
                                   (not (localp (lambda-information-rest-arg lambda))))
                          (list (make-instance 'ast-call
                                               :name '(setf sys.int::%object-ref-t)
                                               :arguments (list (lambda-information-rest-arg lambda)
                                                                new-env
                                                                (make-instance 'ast-quote
                                                                               :value (1+ (position (lambda-information-rest-arg lambda) local-env)))))))
                      ,(lower-env-form (lambda-information-body lambda))))))
          (t (setf (lambda-information-environment-layout lambda) (compute-environment-layout-debug-info))
             (setf (lambda-information-body lambda) (lower-env-form (lambda-information-body lambda)))))
    lambda))

(defun le-let (form)
  (setf (second form)
        (loop for (variable init-form) in (second form)
           collect (list variable (if (or (symbolp variable)
                                          (localp variable))
                                      (lower-env-form init-form)
                                      (make-instance 'ast-call
                                                     :name '(setf sys.int::%object-ref-t)
                                                     :arguments (list (lower-env-form init-form)
                                                                      (second (first *environment-chain*))
                                                                      (make-instance 'ast-quote
                                                                                     :value (1+ (position variable (gethash (first *environment*) *environment-layout*))))))))))
  (setf (cddr form) (mapcar #'lower-env-form (cddr form)))
  form)

(defun get-env-vector (vector-id)
  (let ((chain (assoc vector-id *environment-chain*)))
    (when chain
      (return-from get-env-vector
        (second chain))))
  ;; Not in the chain, walk the rest of the environment.
  (do ((e *environment* (cdr e))
       (c *environment-chain* (cdr c)))
      ((null (cdr c))
       (let ((result (second (car c))))
         (dolist (env (cdr e)
                  (error "Can't find environment for ~S?" vector-id))
           (setf result (make-instance 'ast-call
                                       :name 'sys.int::%object-ref-t
                                       :arguments (list result (make-instance 'ast-quote :value '0))))
           (when (eql env vector-id)
             (return result)))))))

;;; Locate a variable in the environment.
(defun find-var (var env chain)
  (assert chain (var env chain) "No environment chain?")
  (assert env (var env chain) "No environment?")
  (cond ((member var (first env))
         (values (first chain) 0 (position var (first env))))
        ((rest chain)
         (find-var var (rest env) (rest chain)))
        (t ;; Walk the environment using the current chain as a root.
         (let ((depth 0))
           (dolist (e (rest env)
                    (error "~S not found in environment?" var))
             (incf depth)
             (when (member var e)
               (return (values (first chain) depth
                               (position var e)))))))))

(defun le-variable (form)
  (if (localp form)
      form
      (dolist (e *environment*
               (error "Can't find variable ~S in environment." form))
        (let* ((layout (gethash e *environment-layout*))
               (offset (position form layout)))
          (when offset
            (return (make-instance 'ast-call
                                   :name 'sys.int::%object-ref-t
                                   :arguments (list (get-env-vector e)
                                                    (make-instance 'ast-quote :value (1+ offset))))))))))

(defun le-form*-cdr (form)
  (list* (first form)
         (mapcar #'lower-env-form (rest form))))

(defun le-block (form)
  (append (list (first form)
                (second form))
          (when (not (localp (second form)))
            (let ((env-var (second (first *environment-chain*)))
                  (env-offset (1+ (position (second form) (gethash (first *environment*) *environment-layout*)))))
              (setf (block-information-env-var (second form)) env-var
                    (block-information-env-offset (second form)) env-offset)
              (list (make-instance 'ast-call
                                   :name '(setf sys.int::%object-ref-t)
                                   :arguments (list (second form)
                                                    env-var
                                                    (make-instance 'ast-quote
                                                                   :value env-offset))))))
          (mapcar #'lower-env-form (cddr form))))

(defun le-setq (form)
  (cond ((localp (setq-variable form))
         (setf (value form) (lower-env-form (value form)))
         form)
        (t (dolist (e *environment*
                    (error "Can't find variable ~S in environment." (setq-variable form)))
             (let* ((layout (gethash e *environment-layout*))
                    (offset (position (setq-variable form) layout)))
               (when offset
                 (return (make-instance 'ast-call
                                        :name '(setf sys.int::%object-ref-t)
                                        :arguments (list (lower-env-form (value form))
                                                         (get-env-vector e)
                                                         (make-instance 'ast-quote :value (1+ offset)))))))))))


(defun le-variable (form)
  (if (localp form)
      form
      (dolist (e *environment*
               (error "Can't find variable ~S in environment." form))
        (let* ((layout (gethash e *environment-layout*))
               (offset (position form layout)))
          (when offset
            (return (make-instance 'ast-call
                                   :name 'sys.int::%object-ref-t
                                   :arguments (list (get-env-vector e)
                                                    (make-instance 'ast-quote :value (1+ offset))))))))))

(defun le-multiple-value-bind (form)
  (make-instance 'ast-multiple-value-bind
                 :bindings (bindings form)
                 :value-form (lower-env-form (value-form form))
                 :body (make-instance 'ast-progn
                                      :forms (append (mapcan (lambda (var)
                                                               (when (and (not (symbolp var))
                                                                          (not (localp var)))
                                                                 (list (make-instance 'ast-call
                                                                                      :name '(setf sys.int::%object-ref-t)
                                                                                      :arguments (list var
                                                                                                       (second (first *environment-chain*))
                                                                                                       (make-instance 'ast-quote
                                                                                                                      :value (1+ (position var (gethash (first *environment*) *environment-layout*)))))))))
                                                             (bindings form))
                                                     (list (lower-env-form (body form)))))))

(defun le-the (form)
  (setf (third form) (lower-env-form (third form)))
  form)

(defun le-go (form)
  (setf (third form) (lower-env-form (third form)))
  form)

(defun le-tagbody (form)
  (let* ((possible-env-vector-heads (list* (second form)
                                           (remove-if-not #'go-tag-p (cddr form))))
         (env-vector-heads (remove-if (lambda (x) (endp (gethash x *environment-layout*)))
                                      possible-env-vector-heads))
         (new-envs (loop for i in env-vector-heads
                      collect (list i
                                    (make-instance 'lexical-variable
                                                   :name (gensym "Environment")
                                                   :definition-point *current-lambda*)
                                    (gethash i *environment-layout*)))))
    (labels ((frob-outer ()
             `(tagbody ,(second form)
                 ;; Save the tagbody info.
                 ,@(when (not (localp (second form)))
                     (let ((env-var (second (first *environment-chain*)))
                           (env-offset (1+ (position (second form) (gethash (first *environment*) *environment-layout*)))))
                       (setf (tagbody-information-env-var (second form)) env-var
                             (tagbody-information-env-offset (second form)) env-offset)
                       (list (make-instance 'ast-call
                                            :name '(setf sys.int::%object-ref-t)
                                            :arguments (list (second form)
                                                             env-var
                                                             (make-instance 'ast-quote :value env-offset))))))
                 ,@(let ((info (assoc (second form) new-envs)))
                     (when info
                       (if *environment*
                           (list (make-instance 'ast-setq
                                                :variable (second info)
                                                :value (generate-make-environment (second form) (1+ (length (third info)))))
                                 (make-instance 'ast-call
                                                :name '(setf sys.int::%object-ref-t)
                                                :arguments (list (second (first *environment-chain*))
                                                                 (second info)
                                                                 (make-instance 'ast-quote :value '0))))
                           (list (make-instance 'ast-setq
                                                :variable (second info)
                                                :value (generate-make-environment (second form) (1+ (length (third info)))))))))
                 ,@(frob-inner (second form))))
             (frob-inner (current-env)
               (loop for stmt in (cddr form)
                  append (cond ((go-tag-p stmt)
                                (setf current-env stmt)
                                (let ((info (assoc current-env new-envs)))
                                  (append (list stmt)
                                          (when info
                                            (list (make-instance 'ast-setq
                                                                 :variable (second info)
                                                                 :value (generate-make-environment current-env (1+ (length (third info)))))))
                                          (when (and info *environment*)
                                            (list (make-instance 'ast-call
                                                                 :name '(setf sys.int::%object-ref-t)
                                                                 :arguments (list (second (first *environment-chain*))
                                                                                  (second info)
                                                                                  (make-instance 'ast-quote :value '0))))))))
                                (t (let ((info (assoc current-env new-envs)))
                                     (if info
                                         (let ((*environment-chain* (list* (list current-env (second info))
                                                                           *environment-chain*))
                                               (*environment* (list* current-env *environment*)))
                                           (list (lower-env-form stmt)))
                                         (list (lower-env-form stmt)))))))))
      (if (endp new-envs)
          (frob-outer)
          `(let ,(loop for (stmt env layout) in new-envs
                    collect (list env (make-instance 'ast-quote :value 'nil)))
             ,(frob-outer))))))

(defun le-if (form)
  (setf (test form) (lower-env-form (test form))
        (if-then form) (lower-env-form (if-then form))
        (if-else form) (lower-env-form (if-else form)))
  form)

(defun le-return-from (form)
  (setf (third form) (lower-env-form (third form)))
  (setf (fourth form) (lower-env-form (fourth form)))
  form)

;;; org-aws-iam-role.el --- Browse, modify, and simulate AWS IAM Roles in Org Babel -*- lexical-binding: t; -*-

;; Copyright (C) 2025 William Bosch-Bello

;; Author: William Bosch-Bello <williamsbosch@gmail.com>
;; Maintainer: William Bosch-Bello <williamsbosch@gmail.com>
;; Created: August 16, 2025
;; Version: 1.6.1
;; Package-Version: 1.6.1
;; Package-Requires: ((emacs "29.1") (async "1.9") (promise "1.1"))
;; Keywords: aws, iam, org, babel, tools
;; URL: https://github.com/will-abb/org-aws-iam-role
;; Homepage: https://github.com/will-abb/org-aws-iam-role
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by

;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides an interactive interface for browsing and modifying AWS IAM
;; roles directly within Emacs. The package renders all role data in a
;; detailed Org mode buffer and uses a custom Org Babel language,
;; `aws-iam`, to apply policy changes via the AWS CLI.

;; Key Features:
;; - Interactive browsing and selection of IAM roles.
;; - Full display of all policy types: Trust Policy, Permissions Boundary,
;;   AWS-Managed, Customer-Managed, and Inline policies.
;; - Direct modification via Org Babel. Supports "Upsert" logic: automatically
;;   creates policies if they don't exist, or updates them if they do.
;; - Smart Version Management: Automatically offers to delete the oldest
;;   policy version if the AWS version limit is reached during an update.
;; - Advanced Header Arguments: Support for `:tags`, `:path`, and sequential
;;   `:detach` + `:delete` operations.
;; - Built-in IAM Policy Simulator to test a role's permissions against
;;   specific AWS actions and resources.
;; - View a combined JSON policy of all permission policies for easy export.
;; - Asynchronous fetching of initial role and policy data for a fast UI.
;; - Safe by default: the role viewer buffer opens in read-only mode.
;; - Ability to easily switch between different AWS profiles.

;; Keybindings:
;;
;; In the IAM Role Viewer Buffer:
;; - C-c C-e: Toggle read-only mode to enable/disable editing.
;; - C-c C-s: Simulate the role's policies against specific actions.
;; - C-c C-j: View a combined JSON of all permission policies.
;; - C-c C-a: Get service last accessed details for the role.
;; - C-c C-m: Find the last modified date for the role or its policies.
;; - C-c C-c: Inside a source block, apply changes to AWS.
;; - C-c (:   Hide all property drawers.
;; - C-c ):   Reveal all property drawers.
;;
;; In the Simulation Results Buffer:
;; - C-c C-c: Rerun the simulation for the last used role.
;; - C-c C-j: View the raw JSON output from the simulation API call.
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'async)
(require 'promise)
(require 'ob-shell)
(require 'org)
(require 'org-element)


(add-to-list 'org-babel-load-languages '(shell . t))
(add-to-list 'org-src-lang-modes '("aws-iam" . json))
(add-to-list 'org-src-lang-modes '("json" . json))

(defvar org-aws-iam-role-profile nil
  "Default AWS CLI profile to use for IAM role operations.
If nil, uses default profile or environment credentials.")

(defvar org-aws-iam-role-show-folded-by-default nil
  "If non-nil, show the role detail buffer with all sections folded.")

(defvar org-aws-iam-role-fullscreen t
  "If non-nil, show the IAM role buffer in fullscreen.")

(defvar org-aws-iam-role-read-only-by-default t
  "If non-nil, role viewer buffers will be read-only by default.")

(defvar-local org-aws-iam-role-simulate--last-result nil
  "Hold the raw JSON string from the last IAM simulate-principal-policy run.")

(defvar-local org-aws-iam-role-simulate--last-role nil
  "Hold the last IAM Role ARN used for simulate-principal-policy.")

;;;###autoload
(cl-defun org-aws-iam-role-view-details (&optional role-name)
  "Display details for an IAM ROLE-NAME in an Org-mode buffer.
If ROLE-NAME is nil and called interactively, prompt the user.
If ROLE-NAME is provided programmatically, skip prompting."
  (interactive)
  (org-aws-iam-role--check-auth)
  (let* ((name (or role-name
                   (when (called-interactively-p 'any)
                     (completing-read "IAM Role: " (org-aws-iam-role--list-names)))))
         (role (org-aws-iam-role--construct
                (org-aws-iam-role--get-full name))))
    (org-aws-iam-role--show-buffer role)))

;;;###autoload
(defun org-aws-iam-role-set-profile ()
  "Prompt for and set the AWS CLI profile for IAM role operations."
  (interactive)
  (let* ((output (shell-command-to-string "aws configure list-profiles"))
         (profiles (split-string output "\n" t)))
    (setq org-aws-iam-role-profile
          (completing-read "Select AWS profile: " profiles nil t))
    (message "Set IAM Role AWS profile to: %s" org-aws-iam-role-profile)))

(defun org-aws-iam-role--get-account-id ()
  "Fetch the current AWS Account ID using sts get-caller-identity."
  (let* ((cmd (format "aws sts get-caller-identity --output json%s"
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (json-parse-string json :object-type 'alist)))
    (alist-get 'Account parsed)))

(defun org-aws-iam-role-toggle-read-only ()
  "Toggle read-only mode in the current buffer and provide feedback."
  (interactive)
  (if buffer-read-only
      (progn
        (read-only-mode -1)
        (message "Buffer is now editable."))
    (progn
      (read-only-mode 1)
      (message "Buffer is now read-only."))))

;;;;; Internal Helpers & Structs ;;;;;

(defun org-aws-iam-role--cli-profile-arg ()
  "Return the AWS CLI profile argument string, or an empty string."
  (if org-aws-iam-role-profile
      (format " --profile %s" (shell-quote-argument org-aws-iam-role-profile))
    ""))

(defun org-aws-iam-role--check-auth ()
  "Ensure the user is authenticated with AWS, raising an error if not."
  (let* ((cmd (format "aws sts get-caller-identity --output json%s"
                      (org-aws-iam-role--cli-profile-arg)))
         (exit-code (shell-command cmd nil nil)))
    ;; A non-zero exit code from the AWS CLI indicates an error like bad credentials).
    (unless (eq exit-code 0)
      (user-error "AWS CLI not authenticated: please check your credentials or AWS_PROFILE"))))

(defun org-aws-iam-role--format-tags (tags)
  "Format AWS TAGS from a list of alists into a single JSON string.
Argument TAGS is a list of alists of the form
\(\(\"Key\" . \"k1\"\) \(\"Value\" . \"v1\"\)\)."
  (when tags
    ;; We simplify this to a single alist '(( "k1" . "v1" )) for easier JSON encoding.
    (let ((simple-alist (mapcar (lambda (tag)
                                  (cons (alist-get 'Key tag)
                                        (alist-get 'Value tag)))
                                tags)))
      (json-encode simple-alist))))

(cl-defstruct org-aws-iam-role
  name
  arn
  role-id
  path
  create-date
  max-session-duration
  trust-policy
  description
  permissions-boundary-type
  permissions-boundary-arn
  tags
  last-used-region
  last-used-date)

(cl-defstruct org-aws-iam-role-policy
  name
  policy-type
  id
  arn
  path
  description
  is-attachable
  create-date
  update-date
  attachment-count
  default-version-id
  document tags)


;;;;; IAM Policy Data Functions ;;;;;

(defun org-aws-iam-role--policy-get-metadata-async (policy-arn)
  "Fetch policy metadata JSON asynchronously for POLICY-ARN.
Returns a promise that resolves with the raw JSON string from the
`get-policy` command."
  (let* ((cmd (format "aws iam get-policy --policy-arn %s --output json%s"
                      (shell-quote-argument policy-arn)
                      (org-aws-iam-role--cli-profile-arg)))
         (start-func `(lambda () (shell-command-to-string ,cmd))))
    (promise:async-start start-func)))

(defun org-aws-iam-role--policy-get-version-document-async (policy-arn version-id)
  "Fetch policy document JSON for POLICY-ARN and VERSION-ID.
This is an asynchronous operation using `get-policy-version`.
Returns a promise that resolves with the raw JSON string."
  (let* ((cmd (format "aws iam get-policy-version --policy-arn %s --version-id %s --output json%s"
                      (shell-quote-argument policy-arn)
                      (shell-quote-argument version-id)
                      (org-aws-iam-role--cli-profile-arg)))
         (start-func `(lambda () (shell-command-to-string ,cmd))))
    (promise:async-start start-func)))

(defun org-aws-iam-role-policy--construct-from-data (metadata policy-type document-json)
  "Construct an `org-aws-iam-role-policy` struct from resolved data.
METADATA is the parsed `Policy` alist from `get-policy`.
POLICY-TYPE is the type symbol (e.g., `aws-managed`).
DOCUMENT-JSON is the raw JSON string from `get-policy-version`."
  (let* ((policy-version (alist-get 'PolicyVersion (json-parse-string document-json :object-type 'alist)))
         (document-string (alist-get 'Document policy-version))
         ;; The policy document itself is a URL-encoded JSON string inside the parent JSON.
         (document (when document-string
                     (if (stringp document-string)
                         (json-parse-string (url-unhex-string document-string) :object-type 'alist)
                       document-string))))
    (make-org-aws-iam-role-policy
     :name (alist-get 'PolicyName metadata)
     :policy-type policy-type
     :id (alist-get 'PolicyId metadata)
     :arn (alist-get 'Arn metadata)
     :path (alist-get 'Path metadata)
     :description (alist-get 'Description metadata)
     :is-attachable (alist-get 'IsAttachable metadata)
     :create-date (alist-get 'CreateDate metadata)
     :update-date (alist-get 'UpdateDate metadata)
     :attachment-count (alist-get 'AttachmentCount metadata)
     :default-version-id (alist-get 'DefaultVersionId metadata)
     :document document
     :tags (alist-get 'Tags metadata))))

(defun org-aws-iam-role--policy-from-arn-async (policy-arn policy-type)
  "Create an `org-aws-iam-role-policy` struct asynchronously from a policy ARN.
Argument POLICY-ARN is the ARN of the IAM policy.
Argument POLICY-TYPE is the type of the IAM policy.
Returns a promise that resolves with the complete
`org-aws-iam-role-policy` struct."
  (let ((p (promise-chain
               ;; Step 1: Fetch the policy metadata.
               (org-aws-iam-role--policy-get-metadata-async policy-arn)

             ;; Step 2: From metadata, fetch the policy document.
             (then (lambda (metadata-json)
                     (let* ((metadata (alist-get 'Policy (json-parse-string metadata-json :object-type 'alist)))
                            (version-id (alist-get 'DefaultVersionId metadata)))
                       (if version-id
                           (promise-then (org-aws-iam-role--policy-get-version-document-async policy-arn version-id)
                                         (lambda (document-json)
                                           ;; Pass both results to the next step
                                           (list metadata document-json)))
                         ;; Gracefully fail by resolving to nil if no version-id is found.
                         (promise-resolve nil)))))

             ;; Step 3: Construct the final struct from the resolved data.
             (then (lambda (results)
                     (when results
                       (let ((metadata (car results))
                             (document-json (cadr results)))
                         (org-aws-iam-role-policy--construct-from-data metadata policy-type document-json))))))))
    ;; Step 4: Catch any promise rejection in the chain and resolve to nil.
    (promise-catch p (lambda (&rest _) nil))))

(defun org-aws-iam-role-inline-policy--construct-from-json (policy-name json)
  "Construct an inline `org-aws-iam-role-policy` struct from its JSON.
POLICY-NAME is the name of the inline policy. JSON is the raw
string from the `get-role-policy` AWS CLI command."
  (let* ((parsed (json-parse-string json :object-type 'alist :array-type 'list))
         (document (alist-get 'PolicyDocument parsed))
         ;; The policy document is a URL-encoded JSON string inside the parent JSON.
         (decoded-doc (when document
                        (if (stringp document)
                            (json-parse-string (url-unhex-string document) :object-type 'alist :array-type 'list)
                          document))))
    (make-org-aws-iam-role-policy
     :name policy-name
     :policy-type 'inline
     :document decoded-doc)))

(defun org-aws-iam-role--inline-policy-from-name-async (role-name policy-name)
  "Fetch an inline policy asynchronously and construct a struct.
Argument ROLE-NAME is the name of the IAM role.
Argument POLICY-NAME is the name of the inline policy.
Returns a promise that resolves with the `org-aws-iam-role-policy` struct."
  (let* ((cmd (format "aws iam get-role-policy --role-name %s --policy-name %s --output json%s"
                      (shell-quote-argument role-name)
                      (shell-quote-argument policy-name)
                      (org-aws-iam-role--cli-profile-arg)))
         (start-func `(lambda () (shell-command-to-string ,cmd))))
    (promise-chain (promise:async-start start-func)
      (then (lambda (json)
              (org-aws-iam-role-inline-policy--construct-from-json policy-name json))))))


;;;;; IAM Role Data Functions ;;;;;

(defun org-aws-iam-role--fetch-roles-page (marker)
  "Fetch a single page of IAM roles from AWS.
If MARKER is non-nil, it's used as the `--starting-token`.
Returns a cons cell: (LIST-OF-ROLES . NEXT-MARKER)."
  (let* ((cmd (format "aws iam list-roles --output json%s%s"
                      (org-aws-iam-role--cli-profile-arg)
                      (if marker
                          (format " --starting-token %s" (shell-quote-argument marker))
                        "")))
         (json (shell-command-to-string cmd))
         (parsed (json-parse-string json :object-type 'alist :array-type 'list)))
    (cons (alist-get 'Roles parsed) (alist-get 'Marker parsed))))

(defun org-aws-iam-role--list-names ()
  "Return a list of all IAM role names, handling pagination."
  (let ((all-roles '())
        (marker nil)
        (first-run t))
    ;; Loop until the AWS API returns no more pages.
    ;; The `first-run` flag ensures the loop runs at least once when marker starts as nil.
    (while (or first-run marker)
      (let* ((page-result (org-aws-iam-role--fetch-roles-page marker))
             (roles-on-page (car page-result))
             (next-marker (cdr page-result)))
        (setq all-roles (nconc all-roles roles-on-page))
        (setq marker next-marker)
        (setq first-run nil)))
    (mapcar (lambda (r) (alist-get 'RoleName r)) all-roles)))

(defun org-aws-iam-role--get-full (role-name)
  "Fetch full IAM role object for ROLE-NAME from AWS using `get-role`."
  (let* ((cmd (format "aws iam get-role --role-name %s --output json%s"
                      (shell-quote-argument role-name)
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (alist-get 'Role (json-parse-string json :object-type 'alist :array-type 'list))))
    parsed))

(defun org-aws-iam-role--construct (obj)
  "Create an `org-aws-iam-role` struct from a full `get-role` object.
Argument OBJ is the JSON object returned by `get-role`."
  ;; PermissionsBoundary and RoleLastUsed can be nil, so we get them first.
  (let ((pb (alist-get 'PermissionsBoundary obj))
        (last-used (alist-get 'RoleLastUsed obj)))
    (make-org-aws-iam-role
     :name (alist-get 'RoleName obj)
     :arn (alist-get 'Arn obj)
     :role-id (alist-get 'RoleId obj)
     :path (alist-get 'Path obj)
     :create-date (alist-get 'CreateDate obj)
     :max-session-duration (alist-get 'MaxSessionDuration obj)
     :trust-policy (alist-get 'AssumeRolePolicyDocument obj)
     :description (alist-get 'Description obj)
     :permissions-boundary-type (alist-get 'PermissionsBoundaryType pb)
     :permissions-boundary-arn (alist-get 'PermissionsBoundaryArn pb)
     :tags (alist-get 'Tags obj)
     :last-used-region (alist-get 'Region last-used)
     :last-used-date (alist-get 'LastUsedDate last-used))))

(defun org-aws-iam-role--attached-policies (role-name)
  "Return list of attached managed policies for ROLE-NAME."
  (let* ((cmd (format "aws iam list-attached-role-policies --role-name %s --output json%s"
                      (shell-quote-argument role-name)
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (json-parse-string json :object-type 'alist :array-type 'list)))
    (alist-get 'AttachedPolicies parsed)))

(defun org-aws-iam-role--inline-policies (role-name)
  "Return list of inline policy names for ROLE-NAME."
  (let* ((cmd (format "aws iam list-role-policies --role-name %s --output json%s"
                      (shell-quote-argument role-name)
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (json-parse-string json :object-type 'alist :array-type 'list)))
    (alist-get 'PolicyNames parsed)))

(defun org-aws-iam-role--split-managed-policies (attached)
  "Split ATTACHED managed policies into (customer . aws) buckets.
Each bucket keeps the full alist for each policy item."
  (let ((customer '()) (aws '()))
    (dolist (p attached)
      (let ((arn (alist-get 'PolicyArn p)))
        ;; AWS-managed policies have a standard, well-known ARN prefix.
        (if (string-prefix-p "arn:aws:iam::aws:policy/" arn)
            (push p aws)
          (push p customer))))
    (cons (nreverse customer) (nreverse aws))))

;;;;; Display Functions ;;;;;

(defun org-aws-iam-role--insert-role-header (role)
  "Insert the main heading and properties for ROLE into the buffer."
  (insert (format "* IAM Role: %s\n" (org-aws-iam-role-name role)))
  (insert ":PROPERTIES:\n")
  (insert (format ":ARN: %s\n" (org-aws-iam-role-arn role)))
  (insert (format ":RoleID: %s\n" (org-aws-iam-role-role-id role)))
  (insert (format ":Path: %s\n" (org-aws-iam-role-path role)))
  (insert (format ":Created: %s\n" (org-aws-iam-role-create-date role)))
  (insert (format ":MaxSessionDuration: %d\n" (org-aws-iam-role-max-session-duration role)))
  ;; Use "nil" as a string for display if the actual value is nil.
  (insert (format ":Description: %s\n" (or (org-aws-iam-role-description role) "nil")))
  (insert (format ":PermissionsBoundaryArn: %s\n" (or (org-aws-iam-role-permissions-boundary-arn role) "nil")))
  (insert (format ":LastUsedDate: %s\n" (or (org-aws-iam-role-last-used-date role) "nil")))
  (insert (format ":LastUsedRegion: %s\n" (or (org-aws-iam-role-last-used-region role) "nil")))
  (insert (format ":Tags: %s\n" (or (org-aws-iam-role--format-tags (org-aws-iam-role-tags role)) "nil")))
  (insert ":END:\n"))

(defun org-aws-iam-role--insert-trust-policy (role)
  "Insert the trust policy section for ROLE into the buffer."
  (let ((trust-policy-json (json-encode (org-aws-iam-role-trust-policy role)))
        (role-name (org-aws-iam-role-name role)))
    (insert "** Trust Policy\n")
    (insert (format "#+BEGIN_SRC aws-iam :role-name \"%s\" :policy-type \"trust-policy\" :results output\n" role-name))
    (let ((start (point)))
      (insert trust-policy-json)
      ;; Don't let a JSON formatting error stop buffer creation.
      (condition-case nil
          (json-pretty-print start (point))
        (error nil)))
    (insert "\n#+END_SRC\n")))

(defun org-aws-iam-role--format-policy-type (policy-type-symbol)
  "Format POLICY-TYPE-SYMBOL into a human-readable string."
  (cond ((eq policy-type-symbol 'aws-managed) "AWS Managed")
        ((eq policy-type-symbol 'customer-managed) "Customer Managed")
        ((eq policy-type-symbol 'inline) "Inline")
        ((eq policy-type-symbol 'permissions-boundary) "Permissions Boundary")
        (t (capitalize (symbol-name policy-type-symbol)))))

(defun org-aws-iam-role--insert-policy-struct-details (policy role-name)
  "Insert details of a POLICY struct into the buffer for ROLE-NAME."
  (let* ((doc-json (json-encode (org-aws-iam-role-policy-document policy)))
         (policy-type-symbol (org-aws-iam-role-policy-policy-type policy))
         (policy-arn (or (org-aws-iam-role-policy-arn policy) "")))
    (insert (format "*** %s\n" (org-aws-iam-role-policy-name policy)))
    (insert ":PROPERTIES:\n")
    (insert (format ":AWSPolicyType: %s\n" (org-aws-iam-role--format-policy-type policy-type-symbol)))
    (insert (format ":ID: %s\n" (or (org-aws-iam-role-policy-id policy) "nil")))
    (insert (format ":ARN: %s\n" (or policy-arn "nil")))
    (insert (format ":Path: %s\n" (or (org-aws-iam-role-policy-path policy) "nil")))
    (insert (format ":Description: %s\n" (or (org-aws-iam-role-policy-description policy) "nil")))
    (insert (format ":Created: %s\n" (or (org-aws-iam-role-policy-create-date policy) "nil")))
    (insert (format ":Updated: %s\n" (or (org-aws-iam-role-policy-update-date policy) "nil")))
    (insert (format ":AttachmentCount: %s\n" (or (org-aws-iam-role-policy-attachment-count policy) "nil")))
    (insert (format ":DefaultVersion: %s\n" (or (org-aws-iam-role-policy-default-version-id policy) "nil")))
    (insert ":END:\n")
    (insert (format "#+BEGIN_SRC aws-iam :role-name \"%s\" :policy-name \"%s\" :policy-type \"%s\" :arn \"%s\" :results output\n"
                    role-name
                    (org-aws-iam-role-policy-name policy)
                    (symbol-name policy-type-symbol)
                    policy-arn))
    (let ((start (point)))
      (insert doc-json)
      (condition-case nil
          (json-pretty-print start (point))
        (error nil)))
    (insert "\n#+END_SRC\n")))

(defun org-aws-iam-role--insert-remaining-sections-and-finalize (role buf)
  "Insert remaining sections for ROLE and finalize display of BUF."
  (with-current-buffer buf
    (org-aws-iam-role--insert-trust-policy role))
  (org-aws-iam-role--finalize-and-display-role-buffer buf))

(defun org-aws-iam-role--create-policy-promises (role-name boundary-arn attached-policies inline-policy-names)
  "Create a list of promises to fetch all policies.
ROLE-NAME is the role name. BOUNDARY-ARN is its boundary ARN.
ATTACHED-POLICIES is a list of attached policies.
INLINE-POLICY-NAMES is a list of inline policy names."
  (let* ((split (org-aws-iam-role--split-managed-policies attached-policies))
         (customer-managed (car split))
         (aws-managed (cdr split))
         (aws-promises (mapcar (lambda (p) (org-aws-iam-role--policy-from-arn-async (alist-get 'PolicyArn p) 'aws-managed)) aws-managed))
         (customer-promises (mapcar (lambda (p) (org-aws-iam-role--policy-from-arn-async (alist-get 'PolicyArn p) 'customer-managed)) customer-managed))
         (boundary-promise (when boundary-arn (list (org-aws-iam-role--policy-from-arn-async boundary-arn 'permissions-boundary))))
         (inline-promises (mapcar (lambda (name) (org-aws-iam-role--inline-policy-from-name-async role-name name)) inline-policy-names)))
    (append aws-promises customer-promises boundary-promise inline-promises)))

(defun org-aws-iam-role--get-all-policies-async (role)
  "Fetch all attached, inline, and boundary policies for ROLE.
This function is asynchronous and returns a single promise that
resolves with a vector of `org-aws-iam-role-policy` structs when
all underlying fetches are complete. Returns nil if no policies
are found."
  (let* ((role-name (org-aws-iam-role-name role))
         (attached (org-aws-iam-role--attached-policies role-name))
         (inline-policy-names (org-aws-iam-role--inline-policies role-name))
         (boundary-arn (org-aws-iam-role-permissions-boundary-arn role))
         (all-promises (org-aws-iam-role--create-policy-promises
                        role-name boundary-arn attached inline-policy-names)))
    (when all-promises
      (promise-all all-promises))))

(defun org-aws-iam-role--insert-policies-section (all-policies-vector boundary-arn role-name)
  "Render a vector of fetched policies into the current buffer.
ALL-POLICIES-VECTOR is the result from a `promise-all' call.
BOUNDARY-ARN is the original ARN of the boundary policy.
ROLE-NAME is the name of the parent IAM role."
  (let* ((policies-list (seq-into all-policies-vector 'list))
         ;; Filter out any nil results from promises that may have failed gracefully.
         (valid-policies (cl-remove-if-not #'identity policies-list))
         ;; Separate boundary policy from the rest for individual rendering.
         (boundary-policy (cl-find 'permissions-boundary valid-policies :key #'org-aws-iam-role-policy-policy-type))
         (permission-policies (cl-remove 'permissions-boundary valid-policies :key #'org-aws-iam-role-policy-policy-type)))

    ;; 1. Render Permission Policies (AWS, Customer, Inline)
    (insert "** Permission Policies\n")
    (if permission-policies
        (dolist (p permission-policies) (org-aws-iam-role--insert-policy-struct-details p role-name))
      (insert "nil\n"))

    ;; 2. Render Permissions Boundary Policy
    (when boundary-arn
      (insert "** Permissions Boundary Policy\n")
      (if boundary-policy
          (org-aws-iam-role--insert-policy-struct-details boundary-policy role-name)
        (insert "Failed to fetch permissions boundary policy.\n")))))

(defun org-aws-iam-role--insert-buffer-usage-notes ()
  "Insert the usage and keybinding notes into the current buffer."
  (insert "* Usage\n")
  (insert "** Applying Changes via Babel\n")
  (insert "All actions are performed by executing an =aws-iam= source block with =C-c C-c=.\n")
  (insert "You will be asked to confirm before any change is applied.\n")
  (insert "\n- *To Create a New Policy*: Provide a unique =:policy-name= and optional =:path=. If the ARN does not exist, it will be created.\n")
  (insert "- *To Update a Policy*: Edit the JSON. If the policy has reached the version limit, you will be offered to delete the oldest version.\n")
  (insert "- *To Tag*: Add the =:tags= header. Tagging is applied /before/ updates.\n")
  (insert "\nUse header arguments for specific actions:\n")
  (insert "- =:delete t=     :: Deletes the policy. If versions exist, you will be asked to recursively delete them.\n")
  (insert "- =:detach t=     :: Detaches the policy from the current role. Can be combined with =:delete t=.\n")
  (insert "- =:tags=         :: A string of tags (e.g. \"Key=Owner,Value=Dev Key=Stage,Value=Prod\").\n")
  (insert "- =:path=         :: The IAM path for creation (e.g. \"/service-role/\"). Defaults to \"/\".\n")
  (insert "\n** Keybindings\n")
  (insert "- =C-c C-e= :: Toggle read-only mode to allow/prevent edits.\n")
  (insert "- =C-c C-s= :: Simulate the role's policies against specific actions.\n")
  (insert "- =C-c C-j= :: View a combined JSON of all permission policies.\n")
  (insert "- =C-c C-a= :: Get service last accessed details for the role.\n")
  (insert "- =C-c C-m= :: Find the last modified date for the role or its policies.\n")
  (insert "- =C-c C-c= :: Inside a source block, apply changes to AWS.\n")
  (insert "- =C-c (= :: Hide all property drawers.\n")
  (insert "- =C-c )= :: Reveal all property drawers.\n\n"))

(defun org-aws-iam-role--populate-buffer-async-callback (all-policies-vector role buf)
  "Callback to populate BUF with fetched policies for ROLE.
ALL-POLICIES-VECTOR is the resolved vector of policy structs."
  ;; Catch any error during rendering to prevent the callback from crashing.
  (condition-case nil
      (with-current-buffer buf
        (let ((boundary-arn (org-aws-iam-role-permissions-boundary-arn role))
              (role-name (org-aws-iam-role-name role)))
          ;; Insert the fetched policy sections.
          (org-aws-iam-role--insert-policies-section all-policies-vector boundary-arn role-name)
          ;; Insert remaining synchronous sections and finalize the buffer.
          (org-aws-iam-role--insert-remaining-sections-and-finalize role buf)))
    (error nil)))

(defun org-aws-iam-role--populate-role-buffer (role buf)
  "Insert all details for ROLE and its policies into the buffer BUF.
This function orchestrates the asynchronous fetching and rendering of role
information."
  (with-current-buffer buf
    (erase-buffer)
    (org-mode)
    (setq-local org-src-fontify-natively t)
    (org-aws-iam-role--insert-buffer-usage-notes)
    (org-aws-iam-role--insert-role-header role))

  ;; Asynchronously fetch all policies for the role.
  (let ((policies-promise (org-aws-iam-role--get-all-policies-async role)))
    ;; If there are policies, wait for them and then render. Otherwise, render the empty state.
    (if policies-promise
        (promise-then
         policies-promise
         (lambda (all-policies-vector)
           (org-aws-iam-role--populate-buffer-async-callback all-policies-vector role buf)))
      ;; Case where there are no policies of any kind.
      (with-current-buffer buf
        (insert "** Permission Policies\n")
        (insert "nil\n")
        (org-aws-iam-role--insert-remaining-sections-and-finalize role buf)))))

(defun org-aws-iam-role--finalize-and-display-role-buffer (buf)
  "Set keybinds, mode, and display the buffer BUF."
  (with-current-buffer buf
    (local-set-key (kbd "C-c C-e") #'org-aws-iam-role-toggle-read-only)
    (local-set-key (kbd "C-c C-s") #'org-aws-iam-role-simulate-from-buffer)
    (local-set-key (kbd "C-c C-j") #'org-aws-iam-role-combine-permissions-from-buffer)
    (local-set-key (kbd "C-c C-a") #'org-aws-iam-role-get-last-accessed)
    (local-set-key (kbd "C-c C-m") #'org-aws-iam-role-get-last-modified)
    (local-set-key (kbd "C-c (") #'org-fold-hide-drawer-all)
    (local-set-key (kbd "C-c )") #'org-fold-show-all)
    (goto-char (point-min))    (when org-aws-iam-role-read-only-by-default
                                 (read-only-mode 1))
    (if org-aws-iam-role-show-folded-by-default
        (org-overview)
      (org-fold-show-all)))
  ;; Display in a pop-up window.
  (let ((window (display-buffer buf '((display-buffer-pop-up-window)))))
    ;; If fullscreen is enabled, make this the only window.
    (when (and org-aws-iam-role-fullscreen (window-live-p window))
      (select-window window)
      (delete-other-windows))))

(defun org-aws-iam-role--show-buffer (role)
  "Render IAM ROLE object and its policies in a new Org-mode buffer."
  (let* ((timestamp (format-time-string "%Y%m%d-%H%M%S"))
         ;; Add a timestamp to the buffer name for uniqueness.
         (buf-name (format "*IAM Role: %s <%s>*"
                           (org-aws-iam-role-name role)
                           timestamp))
         (buf (get-buffer-create buf-name)))
    (org-aws-iam-role--populate-role-buffer role buf)))

;;;;; Simulation Code Start ;;;;;
(defun org-aws-iam-role-simulate-from-buffer ()
  "Run a policy simulation using the ARN from the current role buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^:ARN:[ \t]+\\(arn:aws:iam::.*\\)$" nil t)
        (org-aws-iam-role-simulate (match-string 1))
      (user-error "Could not find a valid Role ARN in this buffer"))))

(defun org-aws-iam-role-simulate (&optional role-arn)
  "Run a policy simulation for ROLE-ARN."
  (interactive)
  (let* ((role-arn (or role-arn
                       (let* ((roles (org-aws-iam-role--list-names))
                              (role-name (completing-read "IAM Role: " roles)))
                         (org-aws-iam-role-arn
                          (org-aws-iam-role--construct
                           (org-aws-iam-role--get-full role-name)))))))
    (setq org-aws-iam-role-simulate--last-role role-arn)
    (org-aws-iam-role-simulate--for-arn role-arn)))

(defun org-aws-iam-role-simulate-rerun ()
  "Run a simulation using the last stored ROLE-ARN."
  (interactive)
  (if org-aws-iam-role-simulate--last-role
      (org-aws-iam-role-simulate org-aws-iam-role-simulate--last-role)
    (org-aws-iam-role-simulate)))

(defun org-aws-iam-role-simulate--build-cli-command (role-arn actions-str resources-str)
  "Build the `simulate-principal-policy` command string.
Argument ROLE-ARN is the ARN of the role to simulate.
Argument ACTIONS-STR is a space-separated string of actions.
Argument RESOURCES-STR is a space-separated string of resource ARNs."
  (let ((action-args (mapconcat #'shell-quote-argument (split-string actions-str nil t " +") " "))
        (resource-args (if (string-empty-p resources-str)
                           ""
                         (concat " --resource-arns "
                                 (mapconcat #'shell-quote-argument (split-string resources-str nil t " +") " ")))))
    (format "aws iam simulate-principal-policy --policy-source-arn %s --action-names %s%s --output json%s"
            (shell-quote-argument role-arn)
            action-args
            resource-args
            (org-aws-iam-role--cli-profile-arg))))

(defun org-aws-iam-role-simulate--for-arn (role-arn)
  "Simulate the policy for ROLE-ARN after prompting for actions and resources."
  (let* ((actions-str (read-string "Action(s) to test (e.g., s3:ListObjects s3:Put*): "))
         (resources-str (read-string "Resource ARN(s) (e.g., arn:aws:s3:::my-bucket/*): "))
         (cmd (org-aws-iam-role-simulate--build-cli-command role-arn actions-str resources-str))
         (json (or (shell-command-to-string cmd) ""))
         (results (condition-case nil
                      (alist-get 'EvaluationResults
                                 (json-parse-string json :object-type 'alist :array-type 'list))
                    (error nil))))
    (let* ((role-name (car (last (split-string role-arn "/"))))
           (timestamp (format-time-string "%Y%m%d-%H%M%S"))
           (buf (get-buffer-create
                 (format "*IAM Simulation: %s <%s>*" role-name timestamp))))
      (with-current-buffer buf
        (setq-local org-aws-iam-role-simulate--last-role role-arn)
        (setq-local org-aws-iam-role-simulate--last-result json))
      (org-aws-iam-role-simulate--show-result results))))

(defun org-aws-iam-role-simulate--insert-header ()
  "Insert header text and button into the simulation buffer."
  (insert (propertize "Press C-c C-j to view raw JSON output\n" 'face 'font-lock-comment-face))
  (insert (propertize "Press C-c C-c to rerun the simulation for the last role\n\n" 'face 'font-lock-comment-face))
  (insert (propertize "Full list of AWS actions: " 'face 'font-lock-comment-face))
  (insert-button
   "Service Authorization Reference"
   'action (lambda (_)
             (browse-url
              "https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html"))
   'follow-link t
   'face 'link)
  (insert "\n\n"))

(defun org-aws-iam-role-simulate--insert-results (results-list)
  "Insert formatted simulation RESULTS-LIST into the buffer."
  (unless results-list
    (insert (propertize "No simulation results returned. Check the AWS CLI command for errors"
                        'face 'error))
    (cl-return-from org-aws-iam-role-simulate--insert-results))
  (dolist (result-item results-list)
    (org-aws-iam-role-simulate--insert-one-result result-item)))

(defun org-aws-iam-role-simulate--setup-buffer ()
  "Set up local keymap and other buffer-local settings."
  (goto-char (point-min))
  (use-local-map (copy-keymap special-mode-map))
  (local-set-key (kbd "C-c C-j") #'org-aws-iam-role-simulate-show-raw-json)
  (local-set-key (kbd "C-c C-c") #'org-aws-iam-role-simulate-rerun))

(defun org-aws-iam-role-simulate--show-result (results-list)
  "Display RESULTS-LIST from a policy simulation in a new buffer."
  (let* ((role-name (if org-aws-iam-role-simulate--last-role
                        (car (last (split-string org-aws-iam-role-simulate--last-role "/")))
                      "unknown-role"))
         (timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (buf-name (format "*IAM Simulation: %s <%s>*" role-name timestamp))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (erase-buffer)
      (org-aws-iam-role-simulate--insert-header)
      (org-aws-iam-role-simulate--insert-warning)
      (org-aws-iam-role-simulate--insert-results results-list)
      (org-aws-iam-role-simulate--setup-buffer)
      (pop-to-buffer buf))))

(defun org-aws-iam-role-simulate-show-raw-json ()
  "Show the raw JSON from the last IAM simulation in the current buffer."
  (interactive)
  (let* ((json org-aws-iam-role-simulate--last-result)
         (role-arn org-aws-iam-role-simulate--last-role))
    (if (not (and json (stringp json) (not (string-empty-p json))))
        (user-error "No JSON stored from the last simulation in this buffer")
      (let* ((role-name (if role-arn
                            (car (last (split-string role-arn "/")))
                          "unknown-role"))
             (timestamp (format-time-string "%Y%m%d-%H%M%S"))
             (buf (get-buffer-create
                   (format "*IAM Simulate JSON: %s <%s>*" role-name timestamp))))
        (with-current-buffer buf
          (erase-buffer)
          (insert json)
          (condition-case nil
              (json-pretty-print-buffer)
            (error (message "Warning: could not pretty-print JSON")))
          (goto-char (point-min))
          (when (fboundp 'json-mode)
            (json-mode)))
        (pop-to-buffer buf)))))

(defun org-aws-iam-role-simulate--insert-one-result (result-item)
  "Insert the formatted details for a single simulation RESULT-ITEM."
  (let ((parsed-result (org-aws-iam-role-simulate--parse-result-item result-item)))
    (org-aws-iam-role-simulate--insert-parsed-result parsed-result)))

(defun org-aws-iam-role-simulate--insert-parsed-result (parsed-result)
  "Insert a PARSED-RESULT plist into the current buffer."
  (insert (propertize "====================================\n" 'face 'shadow))
  (insert (propertize "Action: " 'face 'font-lock-keyword-face))
  (insert (propertize (plist-get parsed-result :action) 'face 'font-lock-function-name-face))
  (insert "\n")
  (insert (propertize "------------------------------------\n" 'face 'shadow))
  (insert (propertize "Decision:     " 'face 'font-lock-keyword-face))
  (insert (propertize (plist-get parsed-result :decision) 'face (plist-get parsed-result :decision-face)))
  (insert "\n")
  (insert (propertize "Resource:     " 'face 'font-lock-keyword-face))
  (insert (propertize (plist-get parsed-result :resource) 'face 'shadow))
  (insert "\n")
  (insert (propertize "Boundary Allowed: " 'face 'font-lock-keyword-face))
  (let ((pb (plist-get parsed-result :pb-allowed)))
    (insert (propertize (if pb "true" "false") 'face (if pb 'success 'error))))
  (insert "\n")
  (insert (propertize "Org Allowed:   " 'face 'font-lock-keyword-face))
  (let ((org (plist-get parsed-result :org-allowed)))
    (insert (propertize (if org "true" "false") 'face (if org 'success 'error))))
  (insert "\n")
  (insert (propertize "Matched Policies: " 'face 'font-lock-keyword-face))
  (insert (propertize (plist-get parsed-result :policy-ids-str) 'face 'shadow))
  (insert "\n")
  (insert (propertize "Missing Context: " 'face 'font-lock-keyword-face))
  (insert (propertize (plist-get parsed-result :missing-context-str) 'face 'shadow))
  (insert "\n\n"))

(defun org-aws-iam-role-simulate--parse-result-item (result-item)
  "Parse RESULT-ITEM from simulation into a plist for display."
  (let* ((decision (alist-get 'EvalDecision result-item))
         (pb-detail (alist-get 'PermissionsBoundaryDecisionDetail result-item))
         (org-detail (alist-get 'OrganizationsDecisionDetail result-item))
         (matched-statements (alist-get 'MatchedStatements result-item))
         (policy-ids (if matched-statements
                         (mapcar (lambda (stmt) (alist-get 'SourcePolicyId stmt)) matched-statements)
                       '("None")))
         (missing-context (alist-get 'MissingContextValues result-item)))
    `(:action ,(alist-get 'EvalActionName result-item)
      :decision ,decision
      :resource ,(alist-get 'EvalResourceName result-item)
      :pb-allowed ,(if pb-detail (alist-get 'AllowedByPermissionsBoundary pb-detail) nil)
      :org-allowed ,(if org-detail (alist-get 'AllowedByOrganizations org-detail) nil)
      :policy-ids-str ,(mapconcat #'identity policy-ids ", ")
      :missing-context-str ,(if missing-context(mapconcat #'identity missing-context ", ")"None")
      :decision-face ,(if (string= decision "allowed") 'success #'error))))

(defun org-aws-iam-role-simulate--insert-warning ()
  "Insert the standard simulation warning into the current buffer."
  (let ((start (point)))
    (insert "*** WARNING: Simplified Simulation ***\n")
    (insert "This test only checks the role's identity-based policies against the given actions.\n")
    (insert "- It does NOT include resource-based policies (e.g., S3 bucket policies).\n")
    (insert "- It does NOT allow providing specific context keys (e.g., source IP, MFA).\n")
    (insert "- Results ARE affected by Service Control Policies (SCPs).\n\n")
    (insert "For comprehensive testing, use the AWS Console Policy Simulator.\n")
    (insert "************************************\n\n")
    (add-face-text-property start (point) 'font-lock-warning-face)))


;;;;; Iam Babel Code Start ;;;;;
(defun org-aws-iam-role--babel-cmd-for-trust-policy (role-name policy-document)
  "Return the AWS CLI command to update a trust policy for ROLE-NAME.
POLICY-DOCUMENT is the trust policy JSON string."
  (format "aws iam update-assume-role-policy --role-name %s --policy-document %s%s"
          (shell-quote-argument role-name)
          (shell-quote-argument policy-document)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-cmd-for-inline-policy (role-name policy-name policy-document)
  "Return the AWS CLI command to update an inline policy.
ROLE-NAME is the IAM role name. POLICY-NAME is the inline policy name.
POLICY-DOCUMENT is the policy JSON string."
  (format "aws iam put-role-policy --role-name %s --policy-name %s --policy-document %s%s"
          (shell-quote-argument role-name)
          (shell-quote-argument policy-name)
          (shell-quote-argument policy-document)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-cmd-for-managed-policy (policy-arn policy-document)
  "Return the AWS CLI command to update a managed policy.
POLICY-ARN is the ARN of the managed policy.
POLICY-DOCUMENT is the policy JSON string."
  (unless policy-arn
    (user-error "Missing required header argument for managed policy: :arn"))
  (format "aws iam create-policy-version --policy-arn %s --policy-document %s --set-as-default%s"
          (shell-quote-argument policy-arn)
          (shell-quote-argument policy-document)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--param-true-p (val)
  "Return non-nil if VAL is t, or the string \"true\" or \"t\" (case-insensitive)."
  (when val
    (let ((val-str (downcase (format "%s" val))))
      (or (equal val-str "t")
          (equal val-str "true")))))

(defun org-aws-iam-role--policy-exists-p (policy-arn)
  "Return t if the policy with POLICY-ARN exists in AWS, nil otherwise.
Uses \"aws iam get-policy\" and checks the exit code."
  (let ((cmd (format "aws iam get-policy --policy-arn %s%s"
                     (shell-quote-argument policy-arn)
                     (org-aws-iam-role--cli-profile-arg))))
    (eq 0 (call-process-shell-command cmd nil nil nil))))

(defun org-aws-iam-role--babel-cmd-attach-managed-policy (role-name policy-arn)
  "Return the AWS CLI command to attach a managed policy.
ROLE-NAME is the IAM role name. POLICY-ARN is the ARN of the managed policy."
  (format "aws iam attach-role-policy --role-name %s --policy-arn %s%s"
          (shell-quote-argument role-name)
          (shell-quote-argument policy-arn)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-cmd-create-policy (policy-name policy-document &optional path tags)
  "Return the AWS CLI command to create a customer-managed policy.
POLICY-NAME is the name of the new policy.
POLICY-DOCUMENT is the policy JSON string.
PATH is the optional IAM path (e.g., \"/service-role/\").
TAGS is the optional string of tags (e.g. \"Key=Owner,Value=Me\")."
  (format "aws iam create-policy --policy-name %s --policy-document %s%s%s%s"
          (shell-quote-argument policy-name)
          (shell-quote-argument policy-document)
          (if (and path (not (string-empty-p path)))
              (format " --path %s" (shell-quote-argument path))
            "")
          (if (and tags (not (string-empty-p tags)))
              (format " --tags %s" tags) ;; We assume user provides format "Key=K,Value=V ..."
            "")
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--tag-resource (role-name policy-arn policy-type tags)
  "Apply TAGS to an existing resource based on POLICY-TYPE.
If POLICY-TYPE is \='trust-policy', tags the IAM Role ROLE-NAME.
If POLICY-TYPE is \='customer-managed', tags the IAM Policy POLICY-ARN.
Asks for user confirmation before applying.
Returns nil if no tagging was performed or user aborted."
  (when (and tags (not (string-empty-p tags)))
    (cond
     ;; Case 1: Tag the Role (Context is Trust Policy)
     ((eq policy-type 'trust-policy)
      (let ((cmd (format "aws iam tag-role --role-name %s --tags %s%s"
                         (shell-quote-argument role-name)
                         tags
                         (org-aws-iam-role--cli-profile-arg)))
            (prompt (format "Apply tags '%s' to Role '%s'" tags role-name)))
        (if (y-or-n-p (format "%s? " prompt))
            (progn
              (message "Executing: Tag Role...")
              (shell-command-to-string cmd))
          (message "Tagging aborted by user."))))

     ;; Case 2: Tag the Managed Policy
     ((eq policy-type 'customer-managed)
      (let ((cmd (format "aws iam tag-policy --policy-arn %s --tags %s%s"
                         (shell-quote-argument policy-arn)
                         tags
                         (org-aws-iam-role--cli-profile-arg)))
            (prompt (format "Apply tags '%s' to Policy '%s'" tags policy-arn)))
        (if (y-or-n-p (format "%s? " prompt))
            (progn
              (message "Executing: Tag Policy...")
              (shell-command-to-string cmd))
          (message "Tagging aborted by user."))))
     
     ;; Case 3: Inline
     ((eq policy-type 'inline)
      (message "Warning: Inline policies cannot be tagged directly. Tag the Role (Trust Policy) instead.")))))

(defun org-aws-iam-role--babel-cmd-delete-inline-policy (role-name policy-name)
  "Return the AWS CLI command to delete an inline policy.
ROLE-NAME is the IAM role name. POLICY-NAME is the inline policy name."
  (format "aws iam delete-role-policy --role-name %s --policy-name %s%s"
          (shell-quote-argument role-name)
          (shell-quote-argument policy-name)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-cmd-detach-managed-policy (role-name policy-arn)
  "Return the AWS CLI command to detach a managed policy.
ROLE-NAME is the IAM role name. POLICY-ARN is the ARN of the managed policy."
  (format "aws iam detach-role-policy --role-name %s --policy-arn %s%s"
          (shell-quote-argument role-name)
          (shell-quote-argument policy-arn)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-cmd-delete-policy (policy-arn)
  "Return the AWS CLI command to delete a managed policy.
POLICY-ARN is the ARN of the managed policy."
  (format "aws iam delete-policy --policy-arn %s%s"
          (shell-quote-argument policy-arn)
          (org-aws-iam-role--cli-profile-arg)))

(defun org-aws-iam-role--babel-confirm-and-run (cmd description)
  "Prompt user with DESCRIPTION and execute CMD if confirmed."
  (if (y-or-n-p (format "%s?" description))
      (progn
        (message "Executing: %s" description)
        (let ((result (string-trim (shell-command-to-string cmd))))
          (if (string-empty-p result)
              "Success!"
            result)))
    (user-error "Aborted by user")))

(defun org-aws-iam-role--babel-handle-delete (role-name policy-name policy-arn policy-type)
  "Handle the :delete action for `aws-iam' babel blocks.
Argument ROLE-NAME is the name of the IAM role.
Argument POLICY-NAME is the name of the policy.
Argument POLICY-ARN is the ARN of the policy.
Argument POLICY-TYPE is the type of the policy."
  (let (cmd action-desc)
    (cond
     ;; CASE 1: Inline Policy
     ((eq policy-type 'inline)
      (setq action-desc (format "Permanently delete inline policy '%s' from role '%s'" policy-name role-name))
      (setq cmd (org-aws-iam-role--babel-cmd-delete-inline-policy role-name policy-name))
      (org-aws-iam-role--babel-confirm-and-run cmd action-desc))

     ;; CASE 2: Customer Managed Policy
     ((eq policy-type 'customer-managed)
      (let ((versions (org-aws-iam-role--get-all-non-default-versions policy-arn))
            (delete-policy-cmd (org-aws-iam-role--babel-cmd-delete-policy policy-arn)))
        
        (if versions
            ;; Sub-case: Multiple versions exist
            (let ((count (length versions)))
              (if (y-or-n-p (format "Policy has %d non-default versions. Delete ALL versions and the policy '%s'? " count policy-arn))
                  (progn
                    ;; 1. Delete all non-default versions
                    (dolist (ver versions)
                      (message "Deleting version %s..." ver)
                      (let ((del-ver-cmd (format "aws iam delete-policy-version --policy-arn %s --version-id %s%s"
                                                 (shell-quote-argument policy-arn)
                                                 ver
                                                 (org-aws-iam-role--cli-profile-arg))))
                        (shell-command-to-string del-ver-cmd)))
                    
                    ;; 2. Delete the policy itself
                    (message "Deleting policy %s..." policy-arn)
                    (let ((result (string-trim (shell-command-to-string delete-policy-cmd))))
                      (if (string-empty-p result) "Success! Policy and all versions deleted." result)))
                (user-error "Aborted by user")))
          
          ;; Sub-case: No extra versions, just delete the policy
          (setq action-desc (format "Permanently delete managed policy '%s'? (This will fail if it's still attached to any entity)" policy-arn))
          (org-aws-iam-role--babel-confirm-and-run delete-policy-cmd action-desc))))

     (t (user-error "Deletion is only supported for 'inline' and 'customer-managed' policies")))))

(defun org-aws-iam-role--babel-handle-detach (role-name policy-name policy-arn policy-type)
  "Handle the :detach action for `aws-iam' babel blocks.
Argument ROLE-NAME is the name of the IAM role.
Argument POLICY-NAME is the name of the policy.
Argument POLICY-ARN is the ARN of the policy.
Argument POLICY-TYPE is the type of the policy."
  (when (eq policy-type 'inline)
    (user-error "Cannot detach an 'inline' policy. Use :delete instead"))
  (let ((action-desc (format "Detach policy '%s' from role '%s'" (or policy-name policy-arn) role-name))
        (cmd (org-aws-iam-role--babel-cmd-detach-managed-policy role-name policy-arn)))
    (org-aws-iam-role--babel-confirm-and-run cmd action-desc)))

(defun org-aws-iam-role--babel-handle-create (role-name policy-name policy-type body &optional path tags)
  "Handle the creation of a \='customer-managed' policy and optional attachment.
If ROLE-NAME is provided, the new policy is attached to it immediately.
ARGUMENTS: ROLE-NAME, POLICY-NAME, POLICY-TYPE, BODY, PATH, TAGS."
  (if (eq policy-type 'customer-managed)
      (let* ((json-string (json-encode (json-read-from-string body)))
             (create-cmd (org-aws-iam-role--babel-cmd-create-policy policy-name json-string path tags))
             (prompt (if role-name
                         (format "Create policy '%s' (path: %s, tags: %s) AND attach to role '%s'"
                                 policy-name (or path "/") (or tags "none") role-name)
                       (format "Create new customer managed policy '%s' (path: %s, tags: %s)"
                               policy-name (or path "/") (or tags "none")))))
        
        (if (y-or-n-p (format "%s? " prompt))
            (progn
              (message "Executing: Create Policy...")
              ;; Capture the output and trim whitespace
              (let ((output (string-trim (shell-command-to-string create-cmd))))
                
                ;; 1. Check for known CLI text errors (AWS errors often start with "An error...")
                (when (string-prefix-p "An error" output)
                  (user-error "AWS CLI Error: %s" output))

                ;; 2. Attempt to parse JSON safely
                (condition-case _err
                    (let* ((parsed (json-parse-string output :object-type 'alist))
                           (new-policy (alist-get 'Policy parsed))
                           (new-arn (alist-get 'Arn new-policy)))
                      
                      (unless new-arn
                        (error "JSON parsed, but no ARN found. Full Output: %s" output))

                      (if role-name
                          (progn
                            (message "Executing: Attach Policy to Role...")
                            (let ((attach-cmd (org-aws-iam-role--babel-cmd-attach-managed-policy role-name new-arn)))
                              (shell-command-to-string attach-cmd))
                            (format "Success! Created policy '%s' and attached it to '%s'.\nARN: %s"
                                    policy-name role-name new-arn))
                        ;; Else: just return success for creation
                        (format "Success! Created policy '%s'.\nARN: %s" policy-name new-arn)))
                  
                  ;; 3. Catch JSON parsing errors (e.g. other non-JSON text returned)
                  (json-parse-error
                   (user-error "Failed to parse AWS response. The command likely failed. Output: %s" output)))))
          (user-error "Aborted by user")))
    (user-error "The create action is only for 'customer-managed' policies")))

(defun org-aws-iam-role--babel-handle-update (role-name policy-name policy-arn policy-type body)
  "Handle the default update action for `aws-iam' babel blocks.
Argument ROLE-NAME is the name of the IAM role.
Argument POLICY-NAME is the name of the policy.
Argument POLICY-ARN is the ARN of the policy.
Argument POLICY-TYPE is the type of the policy.
Argument BODY is the JSON content of the policy."
  (cond
   ;; 1. Trust Policies (Use standard confirm-and-run)
   ((eq policy-type 'trust-policy)
    (let* ((json-string (json-encode (json-read-from-string body)))
           (action-desc (format "Update Trust Policy for role '%s'" role-name))
           (cmd (org-aws-iam-role--babel-cmd-for-trust-policy role-name json-string)))
      (org-aws-iam-role--babel-confirm-and-run cmd action-desc)))

   ;; 2. Inline Policies (Use standard confirm-and-run)
   ((eq policy-type 'inline)
    (let* ((json-string (json-encode (json-read-from-string body)))
           (action-desc (format "Update inline policy '%s' for role '%s'" policy-name role-name))
           (cmd (org-aws-iam-role--babel-cmd-for-inline-policy role-name policy-name json-string)))
      (org-aws-iam-role--babel-confirm-and-run cmd action-desc)))

   ;; 3. Managed Policies (Use new retry logic)
   ((or (eq policy-type 'customer-managed)
        (eq policy-type 'aws-managed)
        (eq policy-type 'permissions-boundary))
    (org-aws-iam-role--update-managed-policy-with-retry policy-name policy-arn body))

   (t (user-error "Unsupported policy type for modification: %s" policy-type))))

(defun org-aws-iam-role--get-all-non-default-versions (policy-arn)
  "Return a list of VersionIds for all non-default versions of POLICY-ARN."
  (let* ((cmd (format "aws iam list-policy-versions --policy-arn %s --output json%s"
                      (shell-quote-argument policy-arn)
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (condition-case nil
                     (json-parse-string json :object-type 'alist :array-type 'list)
                   (error nil)))
         (versions (alist-get 'Versions parsed)))
    (when versions
      ;; Return only VersionIds where IsDefaultVersion is NOT true
      (mapcar (lambda (v) (alist-get 'VersionId v))
              (cl-remove-if (lambda (v) (eq t (alist-get 'IsDefaultVersion v))) versions)))))

(defun org-aws-iam-role--get-oldest-non-default-version (policy-arn)
  "Return the VersionId of the oldest non-default version for POLICY-ARN."
  (let* ((cmd (format "aws iam list-policy-versions --policy-arn %s --output json%s"
                      (shell-quote-argument policy-arn)
                      (org-aws-iam-role--cli-profile-arg)))
         (json (shell-command-to-string cmd))
         (parsed (json-parse-string json :object-type 'alist :array-type 'list))
         (versions (alist-get 'Versions parsed))
         (non-defaults (cl-remove-if (lambda (v) (eq t (alist-get 'IsDefaultVersion v))) versions)))
    (when non-defaults
      (let ((sorted (sort non-defaults
                          (lambda (a b)
                            (string< (alist-get 'CreateDate a)
                                     (alist-get 'CreateDate b))))))
        (alist-get 'VersionId (car sorted))))))

(defun org-aws-iam-role--update-managed-policy-with-retry (policy-name policy-arn body)
  "Update managed policy POLICY-NAME (POLICY-ARN) with BODY.
Handles version limits by offering to delete the oldest version."
  (let* ((json-string (json-encode (json-read-from-string body)))
         (cmd (org-aws-iam-role--babel-cmd-for-managed-policy policy-arn json-string))
         (action-desc (format "Update managed policy '%s' (ARN: %s)" (or policy-name "unknown") policy-arn)))
    
    (if (y-or-n-p (format "%s? " action-desc))
        (progn
          (message "Executing: Update Policy...")
          (let ((result (string-trim (shell-command-to-string cmd))))
            ;; Check for LimitExceededException in the output
            (if (and (not (string-empty-p result))
                     (string-match-p "LimitExceeded" result))
                
                ;; --- LIMIT REACHED LOGIC ---
                (let ((oldest-ver (org-aws-iam-role--get-oldest-non-default-version policy-arn)))
                  (if (and oldest-ver
                           (y-or-n-p (format "Version limit reached. Delete oldest version (%s) and retry?" oldest-ver)))
                      (progn
                        (message "Deleting version %s..." oldest-ver)
                        (let ((del-cmd (format "aws iam delete-policy-version --policy-arn %s --version-id %s%s"
                                               (shell-quote-argument policy-arn)
                                               oldest-ver
                                               (org-aws-iam-role--cli-profile-arg))))
                          (shell-command-to-string del-cmd))
                        (message "Retrying update...")
                        ;; Retry the original update command
                        (let ((retry-result (string-trim (shell-command-to-string cmd))))
                          (if (string-empty-p retry-result) "Success!" retry-result)))
                    
                    ;; User said no to deletion, or we couldn't find a version to delete
                    (user-error "Update failed (Limit Exceeded): %s" result)))
              
              ;; --- NORMAL SUCCESS/FAILURE LOGIC ---
              (if (string-match-p "An error occurred" result)
                  (user-error "Update failed: %s" result)
                (if (string-empty-p result) "Success!" result)))))
      (user-error "Aborted by user"))))

(defun org-babel-execute:aws-iam (body params)
  "Execute an `aws-iam' source block.
BODY with header PARAMS to manage IAM policies.
PARAMS should include header arguments such as :ROLE-NAME, :POLICY-NAME,
:ARN, :POLICY-TYPE, :PATH, and :TAGS."
  (when buffer-read-only
    (user-error "Buffer is read-only. Press C-c C-e to enable edits and execution"))

  (let* ((role-name (cdr (assoc :role-name params)))
         (policy-name (cdr (assoc :policy-name params)))
         (policy-arn (cdr (assoc :arn params)))
         (policy-path (cdr (assoc :path params)))
         (tags (cdr (assoc :tags params)))
         (policy-type-str (cdr (assoc :policy-type params)))
         (policy-type (when policy-type-str (intern policy-type-str)))
         (delete-p (org-aws-iam-role--param-true-p (cdr (assoc :delete params))))
         (detach-p (org-aws-iam-role--param-true-p (cdr (assoc :detach params))))
         (create-p nil))

    ;; LOGIC FOR CUSTOMER-MANAGED POLICIES ("Upsert" Logic)
    (when (eq policy-type 'customer-managed)
      (unless policy-name
        (user-error "Header argument :policy-name is required for customer-managed policies"))
      
      ;; 1. If ARN is missing OR path is provided, synthesize/recalculate ARN
      (when (or policy-path
                (not policy-arn)
                (string-empty-p policy-arn))
        (let ((account-id (org-aws-iam-role--get-account-id)))
          (unless account-id (error "Could not fetch AWS Account ID to construct ARN"))
          
          ;; Synthesize ARN: arn:aws:iam::ACCOUNT:policy/PATH/NAME
          (let* ((raw-path (if (and policy-path (not (string-empty-p policy-path))) policy-path "/"))
                 (p-start (if (string-prefix-p "/" raw-path) raw-path (concat "/" raw-path)))
                 (p-full (if (string-suffix-p "/" p-start) p-start (concat p-start "/")))
                 (clean-path (substring p-full 1)))
            
            (setq policy-arn (format "arn:aws:iam::%s:policy/%s%s"
                                     account-id clean-path policy-name)))))

      ;; 2. Check existence
      (if (org-aws-iam-role--policy-exists-p policy-arn)
          (setq create-p nil)
        (setq create-p t)))

    (unless (and (or role-name create-p) policy-type)
      (user-error "Missing required header arguments: :ROLE-NAME or :POLICY-TYPE"))

    ;; We collect output messages in a list to support multiple sequential actions.
    (let ((results '()))
      ;; 1. TAGGING (Priority 1)
      ;; Only if we are NOT destroying the resource.
      (when (and (not create-p) tags (not delete-p) (not detach-p))
        (org-aws-iam-role--tag-resource role-name policy-arn policy-type tags))

      ;; 2. DETACH (Priority 2)
      (when detach-p
        (if (eq policy-type 'inline)
            ;; Inline policies cannot be detached, so we skip this step gracefully
            ;; to allow the subsequent DELETE step to handle it.
            (message "Skipping detach for inline policy (implicit in delete).")
          (push (org-aws-iam-role--babel-handle-detach role-name policy-name policy-arn policy-type) results)))

      ;; 3. DELETE (Priority 3)
      (when delete-p
        (push (org-aws-iam-role--babel-handle-delete role-name policy-name policy-arn policy-type) results))

      ;; 4. CREATE / UPDATE (Priority 4)
      ;; Only run if we did NOT perform a destructive action (Detach or Delete).
      (unless (or detach-p delete-p)
        (if create-p
            (push (org-aws-iam-role--babel-handle-create role-name policy-name policy-type body policy-path tags) results)
          (push (org-aws-iam-role--babel-handle-update role-name policy-name policy-arn policy-type body) results)))

      ;; Return concatenated results
      (mapconcat #'identity (nreverse results) "\n"))))


;;;;; unified json start ;;;;;

(defun org-aws-iam-role--get-role-name-from-buffer ()
  "Extract the role name from the main headline of the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\* IAM Role: \\(.*\\)$" nil t)
      (match-string 1))))

(defun org-aws-iam-role--sanitize-for-sid (s)
  "Sanitize string S for use as an IAM Policy Sid.
Removes all non-alphanumeric characters."
  (when s
    (replace-regexp-in-string "[^a-zA-Z0-9]" "" s)))

(defun org-aws-iam-role--parse-modified-date (date-string)
  "Parse a DATE-STRING into an Emacs time list.
Return nil if the string is nil, \"nil\", or invalid."
  (when (and date-string (not (string-empty-p date-string)) (not (string= "nil" date-string)))
    (condition-case nil
        (parse-time-string date-string)
      (error nil))))

(defun org-aws-iam-role--time-greater-p (time-a time-b)
  "Return t if TIME-A is later than TIME-B.
Both are time values like (HIGH LOW . USEC)."
  (let ((high-a (car time-a))
        (low-a (cadr time-a))
        (high-b (car time-b))
        (low-b (cadr time-b)))
    (or (> high-a high-b)
        (and (= high-a high-b)
             (> low-a low-b)))))

(defun org-aws-iam-role--extract-all-permission-statements ()
  "Parse the current buffer to find and extract all permission policy statements.
This function uses a state machine to iterate through headlines,
finds the `Permission Policies' section, and processes the JSON
in each sub-section's source block. It returns a list of all
processed statement alists."
  (let ((all-statements '())
        (tree (org-element-parse-buffer))
        (in-permissions-section nil))
    (org-element-map tree 'headline
      (lambda (hl)
        (let ((level (org-element-property :level hl))
              (title (org-element-property :raw-value hl)))
          (cond
           ;; Case 1: Start of section
           ((and (= level 2) (string= "Permission Policies" title))
            (setq in-permissions-section t))
           ;; Case 2: End of section
           ((and in-permissions-section (= level 2))
            (setq in-permissions-section nil))
           ;; Case 3: Inside section, process policy
           ((and in-permissions-section (= level 3))
            (let* ((policy-name title)
                   (sid (org-aws-iam-role--sanitize-for-sid policy-name))
                   (src-block (car (org-element-map (org-element-contents hl) 'src-block #'identity))))
              (when src-block
                (let* ((json-string (org-element-property :value src-block))
                       (policy-data (json-parse-string json-string :object-type 'alist :array-type 'list))
                       (raw-statements (alist-get 'Statement policy-data))
                       (statements (if (and (consp raw-statements)
                                            (consp (car raw-statements))
                                            (atom (caar raw-statements)))
                                       (list raw-statements)
                                     raw-statements)))
                  (when statements
                    (dolist (stmt statements)
                      (let* ((stmt-no-sid (cl-remove 'Sid stmt :key #'car))
                             (modified-stmt (cons (cons 'Sid sid) stmt-no-sid)))
                        (push modified-stmt all-statements))))))))))))
    (nreverse all-statements)))

(defun org-aws-iam-role--create-and-show-json-buffer (statements role-name)
  "Create and display a new buffer with the combined JSON policy from STATEMENTS.
ROLE-NAME is used for the buffer title."
  (let* ((final-policy `((Version . "2012-10-17")
                         (Statement . ,statements)))
         (json-string (json-encode final-policy))
         (timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (buf-name (format "*IAM Combined Permissions: %s <%s>*" (or role-name "current-role") timestamp))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (erase-buffer)
      (insert json-string)
      (condition-case nil
          (json-pretty-print-buffer)
        (error (message "Warning: could not pretty-print JSON")))
      (goto-char (point-min))
      (when (fboundp 'json-mode)
        (json-mode)))
    (pop-to-buffer buf)))

;;;###autoload
(defun org-aws-iam-role-combine-permissions-from-buffer ()
  "Parse the current Org IAM Role buffer to create a combined JSON policy.
This function acts as an orchestrator, calling helper functions
to extract policy statements and display them in a new buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run from an Org mode buffer"))

  (let ((all-statements (org-aws-iam-role--extract-all-permission-statements)))
    (if (null all-statements)
        (message "No policy statements were found under '** Permission Policies'.")
      (let ((role-name (org-aws-iam-role--get-role-name-from-buffer)))
        (org-aws-iam-role--create-and-show-json-buffer all-statements role-name)))))

;;;###autoload
(defun org-aws-iam-role-get-last-modified ()
  "Find the most recent :Created: or :Updated: timestamp in the buffer.
This parses all property drawers to find the latest date,
which represents the last known modification time of the role or
one of its policies."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run from an Org mode buffer"))
  (let* ((tree (org-element-parse-buffer))
         (all-dates (org-aws-iam-role--collect-dates-from-buffer tree)))
    (org-aws-iam-role--find-latest-date all-dates)))

(defun org-aws-iam-role--collect-dates-from-buffer (tree)
  "Collect all :Created: and :Updated: dates from the parse TREE."
  (let ((all-dates '()))
    (org-element-map tree 'property-drawer
      (lambda (drawer)
        (org-element-map (org-element-contents drawer) 'node-property
          (lambda (prop)
            (let ((key (org-element-property :key prop))
                  (value (org-element-property :value prop)))
              (when (and value (or (string= key "Created") (string= key "Updated")))
                (let ((parsed-date (org-aws-iam-role--parse-modified-date value)))
                  (when parsed-date
                    (push parsed-date all-dates)))))))))
    all-dates))

(defun org-aws-iam-role--find-latest-date (all-dates)
  "Find the latest date in ALL-DATES and return it as a formatted string."
  (if (null all-dates)
      (message "No modified dates found in this buffer.")
    (let* ((latest-time-DECODED (car all-dates))
           (time-val-current nil)
           (time-val-latest nil)
           (is-greater nil)
           (final-time-VALUE nil))
      (dolist (current-date-DECODED (cdr all-dates))
        (setq time-val-current (apply #'encode-time current-date-DECODED))
        (setq time-val-latest (apply #'encode-time latest-time-DECODED))
        (setq is-greater (org-aws-iam-role--time-greater-p time-val-current time-val-latest))
        (when is-greater
          (setq latest-time-DECODED current-date-DECODED)))
      (setq final-time-VALUE (apply #'encode-time latest-time-DECODED))
      (let ((latest-date-string (format-time-string "%FT%T%z" final-time-VALUE)))
        (message "Last modification date found: %s" latest-date-string)))))

;;;;; Last Accessed Details ;;;;;

(defun org-aws-iam-role--show-last-accessed-json (json-string role-arn)
  "Display the final JSON-STRING in a new buffer for ROLE-ARN."
  (let* ((role-name (if role-arn
                        (car (last (split-string role-arn "/")))
                      "unknown-role"))
         (timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (buf (get-buffer-create
               (format "*IAM Last Accessed: %s <%s>*" role-name timestamp))))
    (with-current-buffer buf
      (erase-buffer)
      (insert json-string)
      (condition-case nil
          (json-pretty-print-buffer)
        (error (message "Warning: could not pretty-print JSON")))
      (goto-char (point-min))
      (when (fboundp 'json-mode)
        (json-mode)))
    (pop-to-buffer buf)))

(defun org-aws-iam-role--generate-last-accessed-job (role-arn)
  "Start the `generate-service-last-accessed-details` job for ROLE-ARN.
Returns the JobId string."
  (message "Starting generation for last accessed report for %s..." role-arn)
  (let* ((cmd (format "aws iam generate-service-last-accessed-details --arn %s --granularity ACTION_LEVEL --output json%s"
                      (shell-quote-argument role-arn)
                      (org-aws-iam-role--cli-profile-arg)))
         (json-result (shell-command-to-string cmd))
         (job-id (alist-get 'JobId (json-parse-string json-result :object-type 'alist))))
    (unless (and job-id (stringp job-id) (not (string-empty-p job-id)))
      (user-error "Failed to get JobId from AWS: %s" json-result))
    (message "Report job started (JobId: %s). Polling for results... (This will freeze Emacs)" job-id)
    job-id))

(defun org-aws-iam-role--poll-last-accessed-job (job-id)
  "Poll the `get-service-last-accessed-details` job for JOB-ID.
Returns the final JSON string on `COMPLETED`, or errors out."
  (let ((final-json nil)
        (retries 12)
        (poll-cmd (format "aws iam get-service-last-accessed-details --job-id %s --output json%s"
                          (shell-quote-argument job-id)
                          (org-aws-iam-role--cli-profile-arg))))
    (while (and (not final-json) (> retries 0))
      (let* ((poll-result (shell-command-to-string poll-cmd))
             (parsed (condition-case nil
                         (json-parse-string poll-result :object-type 'alist)
                       (error nil)))
             (status (and parsed (alist-get 'JobStatus parsed))))
        (cond
         ((string= status "COMPLETED")
          (message "Job complete!")
          (setq final-json poll-result))
         ((string= status "FAILED")
          (user-error "AWS Job failed: %s" poll-result))
         ((string= status "IN_PROGRESS")
          (setq retries (1- retries))
          (message "Job in progress... polling again in 5s. (Retries left: %d)" retries)
          (sleep-for 5))
         (t
          (user-error "Invalid job status or JSON: %s" (or status poll-result))))))
    (unless final-json
      (user-error "Timeout waiting for last-accessed-details job"))
    final-json))

;;;###autoload
(defun org-aws-iam-role-get-last-accessed (&optional role-arn)
  "Generate and display the service last accessed details.
If ROLE-ARN is nil (e.g., when called interactively),
find it from the current buffer's ARN property.
This is a synchronous (blocking) operation and will freeze
Emacs for up to a minute while polling for results."
  (interactive
   ;; This block runs when called interactively
   (list
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward "^:ARN:[ \t]+\\(arn:aws:iam::[^ \n\r]*\\)$" nil t)
          (match-string 1)
        (user-error "Could not find a valid Role ARN in this buffer")))))

  (unless (and role-arn (stringp role-arn))
    (user-error "No valid Role ARN found or provided"))

  (let* ((job-id (org-aws-iam-role--generate-last-accessed-job role-arn))
         (final-json (org-aws-iam-role--poll-last-accessed-job job-id)))
    (org-aws-iam-role--show-last-accessed-json final-json role-arn)))

(provide 'org-aws-iam-role)
;;; org-aws-iam-role.el ends here

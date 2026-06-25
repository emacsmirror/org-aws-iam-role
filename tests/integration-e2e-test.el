;;; tests/integration-e2e-test.el --- ERT integration test for org-aws-iam-role -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-aws-iam-role)
(require 'cl-lib)

;; Ensure default-directory is sane (important for batch runs).
(setq default-directory
      (or (file-name-directory load-file-name)
          (file-name-directory buffer-file-name)
          default-directory))

(defvar org-aws-iam-role-test-async-timeout 60
  "Seconds to wait for async IAM role buffer rendering in integration tests.")

(defun org-aws-iam-role-test--buffer-matches-p (buffer regexp)
  "Return non-nil when BUFFER contains REGEXP."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (re-search-forward regexp nil t)))))

(defun org-aws-iam-role-test--wait-for-buffer-regexp (buffer regexp &optional timeout)
  "Wait until BUFFER contains REGEXP, or until TIMEOUT seconds elapse."
  (let ((deadline (+ (float-time) (or timeout org-aws-iam-role-test-async-timeout)))
        found)
    (while (and (not found)
                (buffer-live-p buffer)
                (< (float-time) deadline))
      (setq found (org-aws-iam-role-test--buffer-matches-p buffer regexp))
      (unless found
        (accept-process-output nil 0.25)))
    found))

(defun org-aws-iam-role-test--find-role-buffer (role-name)
  "Find an IAM role buffer for ROLE-NAME."
  (cl-find-if (lambda (buf)
                (string-match-p
                 (concat "\\*IAM Role: " (regexp-quote role-name))
                 (buffer-name buf)))
              (buffer-list)))

(defun org-aws-iam-role-test--wait-for-role-buffer-regexp (role-name regexp &optional timeout)
  "Wait until ROLE-NAME's IAM role buffer exists and contains REGEXP."
  (let ((deadline (+ (float-time) (or timeout org-aws-iam-role-test-async-timeout)))
        role-buffer)
    (while (and (not (and role-buffer
                          (org-aws-iam-role-test--buffer-matches-p role-buffer regexp)))
                (< (float-time) deadline))
      (setq role-buffer (org-aws-iam-role-test--find-role-buffer role-name))
      (unless (and role-buffer
                   (org-aws-iam-role-test--buffer-matches-p role-buffer regexp))
        (accept-process-output nil 0.25)))
    role-buffer))

;; First test: basic fetch
(ert-deftest org-aws-iam-role/get-full-basic-test ()
  "Call `org-aws-iam-role--get-full` with a test role and log result."
  (let ((test-role-name "test-iam-packageIamRole")
        (org-aws-iam-role-profile "williseed-iam-tester"))
    (message "DEBUG calling org-aws-iam-role--get-full with %S" test-role-name)
    (let ((role-obj (org-aws-iam-role--get-full test-role-name)))
      (message "DEBUG role-obj=%S" role-obj)
      (should role-obj))))

;; Second test: construct struct from role object
(ert-deftest org-aws-iam-role/construct-basic-test ()
  "Call `org-aws-iam-role--construct` on role object and check struct."
  (let ((test-role-name "test-iam-packageIamRole")
        (org-aws-iam-role-profile "williseed-iam-tester"))
    (let* ((role-obj (org-aws-iam-role--get-full test-role-name))
           (role-struct (org-aws-iam-role--construct role-obj)))
      (message "DEBUG role-struct=%S" role-struct)
      (should (org-aws-iam-role-p role-struct)))))

;; Third test: populate role buffer
(ert-deftest org-aws-iam-role/populate-buffer-basic-test ()
  "Populate a buffer with role details and check it contains expected markers."
  (let ((test-role-name "test-iam-packageIamRole")
        (org-aws-iam-role-profile "williseed-iam-tester"))
    (let* ((role-obj (org-aws-iam-role--get-full test-role-name))
           (role-struct (org-aws-iam-role--construct role-obj)))
      (with-temp-buffer
        (org-aws-iam-role--populate-role-buffer role-struct (current-buffer))
        ;; CRITICAL: We must wait for asynchronous policy fetching to complete.
        (should
         (org-aws-iam-role-test--wait-for-buffer-regexp
          (current-buffer)
          "^\\*\\* Permission Policies"))
        (goto-char (point-min))
        (let ((buf-str (buffer-string)))
          (message "DEBUG buffer-start=%s"
                   (substring buf-str 0 (min 200 (length buf-str))))
          (should (string-match-p "\\* IAM Role:" buf-str))
          (should (string-match-p "\\*\\* Permission Policies" buf-str)))))))

;; Helper function to normalize strings for a stable comparison.
(defun org-aws-iam-role-test--normalize-string (str)
  "Normalize STR by removing the unique timestamp and standardizing newlines."
  (when str
    (let ((s (replace-regexp-in-string " <[0-9-]+>" "" str)))
      (replace-regexp-in-string "\r\n" "\n" s))))

;; Fourth test: Final regression test against the golden file.
(ert-deftest org-aws-iam-role/regression-test-against-golden-file ()
  "Call the main view function and compare the created buffer against the golden file."
  (let ((test-role-name "test-iam-packageIamRole")
        (org-aws-iam-role-profile "williseed-iam-tester")
        (golden-file (expand-file-name
                      "fixtures/integration-e2e-test-output.org"
                      (or (and load-file-name (file-name-directory load-file-name))
                          (and buffer-file-name (file-name-directory buffer-file-name))
                          default-directory))))

    (should (file-exists-p golden-file))

    ;; Call the main entry point to create the buffer.
    (org-aws-iam-role-view-details test-role-name)

    (let* ((role-buffer
            (org-aws-iam-role-test--wait-for-role-buffer-regexp
             test-role-name
             "^\\*\\* Permission Policies"))
           (actual-content
            (when role-buffer
              (with-current-buffer role-buffer
                (prog1 (buffer-string)
                  (kill-buffer (current-buffer))))))
           (expected-content
            (with-temp-buffer
              (insert-file-contents golden-file)
              (buffer-string)))
           (normalized-actual (org-aws-iam-role-test--normalize-string actual-content))
           (normalized-expected (org-aws-iam-role-test--normalize-string expected-content)))

      (should normalized-actual) ;; Make sure we found the buffer.
      (should (string= normalized-actual normalized-expected)))))


(provide 'integration-e2e-test)

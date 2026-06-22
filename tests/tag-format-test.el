;;; tests/tag-format-test.el --- Unit tests for tag formatting -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org-aws-iam-role)

(defvar flycheck-disabled-checkers)
(defvar flycheck-checker)
(defvar async-prompt-for-password)

(ert-deftest org-aws-iam-role/disables-org-lint-flycheck-checker ()
  "Generated role buffers should not run the flaky `org-lint' checker."
  (with-temp-buffer
    (setq-local flycheck-disabled-checkers '(emacs-lisp org-lint))
    (setq-local flycheck-checker 'org-lint)
    (org-aws-iam-role--disable-org-lint-checker)
    (should (equal flycheck-disabled-checkers '(org-lint emacs-lisp)))
    (should-not flycheck-checker)))

(ert-deftest org-aws-iam-role/async-shell-command-disables-password-prompt ()
  "AWS async fetches should not trigger async.el password forwarding."
  (let ((async-prompt-for-password t))
    (cl-letf (((symbol-function 'promise:async-start)
               (lambda (&rest _)
                 async-prompt-for-password)))
      (should-not
       (org-aws-iam-role--async-shell-command-to-string "printf test")))))

(ert-deftest org-aws-iam-role/async-callback-ignores-killed-buffer ()
  "Late async callbacks should not write to killed role buffers."
  (let ((buf (generate-new-buffer " *dead iam role*"))
        (role (make-org-aws-iam-role :name "dead-role")))
    (kill-buffer buf)
    (should-not
     (org-aws-iam-role--populate-buffer-async-callback [] role buf))))

(ert-deftest org-aws-iam-role/normalize-tags-accepts-shorthand-pairs ()
  "Comma+space delimited key=value pairs should be accepted and normalized."
  (should
   (equal
    (org-aws-iam-role--normalize-tags "owner=hello there, name=noneya")
    '(("owner" . "hello there") ("name" . "noneya"))))
  (should
   (equal
    (org-aws-iam-role--render-tags-for-display
     (org-aws-iam-role--normalize-tags "owner= hello there, name=noneya"))
    "Key=owner,Value= hello there Key=name,Value=noneya")))

(ert-deftest org-aws-iam-role/normalize-tags-rejects-invalid-format ()
  "Invalid tag formats should return nil."
  (should (equal (org-aws-iam-role--normalize-tags "Env=prod")
                 '(("Env" . "prod"))))
  (should (equal (org-aws-iam-role--normalize-tags "owner=")
                 '(("owner" . ""))))
  (should-not (org-aws-iam-role--normalize-tags "owner"))
  (should-not (org-aws-iam-role--normalize-tags "Key=Owner,Value=Dev"))
  (should-not (org-aws-iam-role--normalize-tags "owner=devops env=prod")))

(ert-deftest org-aws-iam-role/tags-valid-p-accepts-shorthand-pairs ()
  "Validation helper should accept comma+space key=value pairs."
  (should (org-aws-iam-role--tags-valid-p "owner=hello there, name=noneya"))
  (should-not (org-aws-iam-role--tags-valid-p "Key=Owner,Value=DevOps")))

(provide 'tag-format-test)

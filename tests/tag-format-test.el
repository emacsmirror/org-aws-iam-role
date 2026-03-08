;;; tests/tag-format-test.el --- Unit tests for tag formatting -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-aws-iam-role)

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

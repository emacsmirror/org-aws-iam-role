# Org AWS IAM Role for Emacs

`org-aws-iam-role.el` is an Emacs package for inspecting **and modifying** AWS IAM roles and their policy documents. It renders all role data—including trust policies, permissions boundaries, and all associated policies (AWS managed, customer managed, and inline)—in an interactive Org-mode buffer. It also includes IAM policy simulator to test a role's permissions against specific actions and resources directly within Emacs.

This package uses Org Babel and the AWS CLI under the hood, allowing you to edit policies directly in the buffer and apply them to your AWS account. All initial policy data is fetched **asynchronously and in parallel**.

-----

## Demonstration

[![Org AWS IAM Role for Emacs Demo](https://img.youtube.com/vi/HaYiXQqAoJw/hqdefault.jpg)](https://youtu.be/HaYiXQqAoJw)

-----

## Features

  * **Browse and Inspect IAM Roles** via an interactive prompt.
  * **Modify IAM Policies**: Edit policies directly in the Org buffer and apply changes by executing the source block (`C-c C-c`).
      * Supports Trust Policies, Permissions Boundaries, Customer-Managed, AWS-Managed, and Inline policies.
  * **Smart Upsert Logic**: Automatically detects if a policy needs to be created or updated based on the Name/Path/ARN.
  * **Version Management**: If a managed policy hits the AWS version limit (usually 5), the package offers to delete the oldest non-default version and retry the update automatically.
  * **Tagging & Paths**: Support for adding tags (`:tags`) and specifying IAM paths (`:path`) during creation or updates.
  * **Sequential Operations**: Support for detaching and deleting policies in a single execution (`:detach t :delete t`).
  * **IAM Policy Simulator**: Test the role's permissions against a list of actions and resources using `iam:SimulatePrincipalPolicy` (`C-c C-s`).
  * **View Combined Permissions**: Generate a single, unified JSON policy from all permission policies (`Customer-Managed`, `AWS-Managed`, and `Inline`) for a holistic view (`C-c C-j`).
  * **Get Service Last Accessed Details**: Fetches a report from AWS showing when services were last accessed by the role, using `iam:GenerateServiceLastAccessedDetails` (`C-c C-a`).
  * **Get Last Modified Date**: Scans the buffer to find the most recent creation or update timestamp among the role and all its policies (`C-c C-m`).
  * **Read-Only by Default**: Buffers open in a safe, read-only mode to prevent accidental changes. Toggle editing with a keypress.
  * **Org Babel Integration** using a custom `aws-iam` language for applying changes.
  * **Asynchronous Parallel Fetching** for fast initial loading of all policies.
  * **Org-mode Rendering** with foldable sections for easy navigation.
  * **Switch AWS CLI profiles** interactively.
  * **Authenticates via CLI** and alerts on credential issues before running commands.

-----

## Requirements

  * **GNU Emacs 29.1+**
  * AWS CLI installed and in your `PATH`
  * Permissions for the following AWS IAM APIs:
      * `sts:GetCallerIdentity`
      * `iam:GetRole`
      * `iam:ListRoles`
      * `iam:ListAttachedRolePolicies`
      * `iam:ListRolePolicies`
      * `iam:GetPolicy`
      * `iam:GetPolicyVersion`
      * `iam:GetRolePolicy`
      * `iam:UpdateAssumeRolePolicy` (to modify trust policies)
      * `iam:PutRolePolicy` (to modify inline policies)
      * `iam:CreatePolicy` (to create new policies)
      * `iam:CreatePolicyVersion` (to modify managed policies)
      * `iam:DeletePolicy` and `iam:DeletePolicyVersion`
      * `iam:AttachRolePolicy` and `iam:DetachRolePolicy`
      * `iam:TagRole` and `iam:TagPolicy`
      * `iam:SimulatePrincipalPolicy` (for the policy simulator)
      * `iam:GenerateServiceLastAccessedDetails` (for last accessed report)
      * `iam:GetServiceLastAccessedDetails` (for last accessed report)

Emacs libraries used: `cl-lib`, `json`, `url-util`, `async`, `promise`, `ob-shell`.

-----

## Usage

1.  Load the package (e.g. `(require 'org-aws-iam-role)`)
2.  Run:
    `M-x org-aws-iam-role-view-details`
3.  Select a role from the list.
4.  The buffer will open in read-only mode. To make changes:
    a.  Press `C-c C-e` to toggle editable mode.
    b.  Modify the JSON inside any policy's source block.
    c.  Press `C-c C-c` inside the block to apply the changes to AWS.
    d.  View the success or failure message in the `#+RESULTS:` block that appears.
5.  To test the role's effective permissions, press `C-c C-s` at any time to open the IAM policy simulator.

### Babel Header Arguments

| Header Argument | Description                                                | Example                |
|:----------------|:-----------------------------------------------------------|:-----------------------|
| `:policy-name`  | Required for creation. The name of the policy.             | `"MyPolicy"`           |
| `:path`         | Optional. IAM path for the policy (creation only).         | `"/service-role/"`     |
| `:tags`         | Optional. Space-separated Key=Value pairs.                 | `"Key=Env,Value=Prod"` |
| `:detach t`     | Detach the policy from the role.                           | `:detach t`            |
| `:delete t`     | Delete the policy. Recursively deletes versions if needed. | `:delete t`            |

### Org Buffer Keybindings

| Keybinding | Description                                               |
|:-----------|:----------------------------------------------------------|
| `C-c C-e`  | Toggle read-only mode to allow/prevent edits.             |
| `C-c C-s`  | Simulate the role's policies against specific actions.    |
| `C-c C-j`  | View a combined JSON of all permission policies.          |
| `C-c C-a`  | Get service last accessed details for the role.           |
| `C-c C-m`  | Find the last modified date for the role or its policies. |
| `C-c C-c`  | Inside a source block, apply changes to AWS.              |
| `C-c (`    | Hide all property drawers.                                |
| `C-c )`    | Reveal all property drawers.                              |

-----

## Configuration

Optional variables for customizing behavior:

```elisp
(setq org-aws-iam-role-profile "my-profile") ;; Use a specific AWS CLI profile
(setq org-aws-iam-role-show-folded-by-default t) ;; Show Org buffer folded by default
(setq org-aws-iam-role-fullscreen nil) ;; Prevent the buffer from taking the full frame
```

To change the profile at runtime, you can run:
`M-x org-aws-iam-role-set-profile`

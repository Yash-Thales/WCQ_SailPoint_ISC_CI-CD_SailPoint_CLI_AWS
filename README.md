# SailPoint Identity Security Cloud (ISC) GitOps CI/CD Pipeline

This repository contains the complete, production-ready GitOps CI/CD template for automating deployments and synchronization of **SailPoint Identity Security Cloud (ISC)** configuration objects across **DEV**, **UAT**, and **PROD** tenants, integrated securely with **AWS Secrets Manager**.

---

## 1. Pipeline Architecture

```
[Developer Edits JSONs]
         │
         ▼
    [git push]
         │
  ┌──────┴──────────────────────────┐
  ▼                                 ▼
[dev branch]                   [uat / main branches]
  │                                 │
  ▼ (Direct)                        ▼ (Requires Approval)
[DEV Runner]                   [UAT (1 Reviewer) / PROD (2 Reviewers)]
  │                                 │
  ├─────────────────────────────────┘
  ▼
[1. Validate JSON Syntax]
  │
  ▼
[2. Configure AWS Credentials] (OIDC or IAM Keys)
  │
  ▼
[3. Fetch Secret String (JSON)] (from AWS Secrets Manager)
  │
  ▼
[4. Mask Secrets (***)] (GitHub Actions log parser)
  │
  ▼
[5. Run deploy_cli.sh]
  ├─► Compile & Tokenize changed config JSONs
  ├─► Update UI Branding via REST API (PUT /v3/brandings/default)
  └─► Import package via SailPoint CLI (sail spconfig import)
```

---

## 2. Key Features & Safeguards

*   **Always-Incremental Deployments:** The deployment script compares Git history differences (`git diff HEAD~1`) and tokenizes/pushes *only* the specific JSON files that changed. This prevents bulk-import timeouts and API 504 gateway errors.
*   **Fail-Fast JSON Validation:** Before executing any API calls or installing the CLI, the pipeline runs local syntax validation on all configurations. If a syntax error (like a missing comma) exists, the run halts immediately.
*   **Zero-Keys at Rest & Masking Security:** All passwords and API keys are stored encrypted in AWS Secrets Manager. Secrets are decrypted only in the runner's memory during compilation and are immediately masked in the workflow logs (hidden as `***`).
*   **SaaS Connector Uploads:** A dedicated workflow (`deploy_connectors.yml`) packages and uploads custom web/SaaS connectors utilizing the official `sailpoint-oss/upload-saas-connector@v1` Action.
*   **Dynamic Version-Pinned CLI:** Pinned to version `2.2.12` for build repeatability, with an automated update checker warning you in the UI when a new release is available from SailPoint.

---

## 3. Branch & Environment Mapping

The pipeline dynamically maps branches to environments and enforces deployment approval gates:

| Git Branch | Target Tenant | Approval Gates | Authentication Source |
| :--- | :--- | :--- | :--- |
| **`dev`** | DEV/Sandbox | **Direct Deploy** (Immediate) | AWS Secret: `sailpoint-config-dev` |
| **`uat`** | UAT/Staging | **1 Required Reviewer** | AWS Secret: `sailpoint-config-uat` |
| **`main`** | PROD/Production | **2 Required Reviewers** | AWS Secret: `sailpoint-config-prod` |

---

## 4. Secrets Configuration

### Step 1: Configure AWS Secrets Manager
For each environment, create a Secret in your AWS Secrets Manager console using the **Key/value pairs** option:
1.  **DEV:** Secret named `sailpoint-config-dev`
2.  **UAT:** Secret named `sailpoint-config-uat`
3.  **PROD:** Secret named `sailpoint-config-prod`

Inside each secret, define the following keys:
*   `SAIL_BASE_URL`: Your SailPoint tenant URL (e.g. `https://tenant.api.identitynow.com`).
*   `SAIL_CLIENT_ID`: Your SailPoint API Client ID.
*   `SAIL_CLIENT_SECRET`: Your SailPoint API Client Secret.
*   *Other config secrets* (e.g., `AD_ADMIN_PASSWORD`): Place them here! The pipeline automatically retrieves and tokenizes them.

### Step 2: Configure GitHub Repository Secrets
Add your AWS connection keys under `Settings` -> `Secrets and variables` -> `Actions` -> `Repository secrets`:
*   `AWS_ACCESS_KEY_ID`
*   `AWS_SECRET_ACCESS_KEY`

*(Note: Change the `AWS_REGION` variable at the top of the `.yml` workflow files to match your target AWS region).*

---

## 5. Script Executions

### Running Deployments Locally (`deploy_local.ps1`)
To test a configuration locally on your laptop without pushing to GitHub, you can execute the PowerShell script:
```powershell
./scripts/deploy_local.ps1 -Environment DEV
```
*   It reads local replacement configurations from `environments/dev.json`.
*   It tokenizes the config files in memory.
*   It packages and pushes them to your DEV tenant using the local SailPoint CLI.
*   *(If environment credentials are not set, it prompts you securely in the terminal; it never saves credentials to disk).*

### Backing Up UI Changes (`export.sh`)
If configurations or brand colors are modified directly in the SailPoint UI, you can trigger the **Export Workflow** in GitHub Actions:
1.  Go to the **Actions** tab on GitHub and select **Export SailPoint ISC Configuration**.
2.  Click **Run workflow**, choose your branch (e.g. `dev`), and trigger it.
3.  The runner executes `scripts/export.sh` using the AWS Secret credentials and automatically commits the updated JSON files back to your Git branch.
4.  Run `git pull` locally in your workspace to sync your editor.

# Gmail_Archive

**A PowerShell tool for archiving Gmail conversations as local HTML files, including attachments.**

Gmail_Archive selects conversations using a Gmail label, exports the complete conversation in chronological order, and organizes the results into folders based on Gmail labels.

Designed for Windows PowerShell 5.1 and personal Gmail archives.

## Features

- **Complete conversations:** If any message in a Gmail conversation has the configured trigger label, the entire conversation is archived.
- **Readable HTML:** Messages are saved in chronological order, with sender and recipient information.
- **Attachments:** Downloads attachments and links them from the archived HTML.
- **Label-based folders:** Organizes conversations by Gmail user labels. Conversations with multiple relevant labels can appear in multiple archive folders.
- **Customizable filenames:** Configure filename lengths and exclude your own email addresses from participant names.
- **Archive index:** Tracks archived messages and detects changes, avoiding unnecessary exports.
- **HTML activity log:** A searchable, filterable log with run summaries, warnings, errors, and separate categories for unchanged and intentionally skipped conversations.
- **Progress and retries:** Displays progress and retries temporary Gmail API failures.
- **Test mode:** Supports dry runs before making archive changes.
- **Configurable:** Settings live in a separate PowerShell data file (`.psd1`).

## Requirements

- Windows with **Windows PowerShell 5.1**
- A Google account with Gmail
- A Google Cloud project with the **Gmail API** enabled
- OAuth desktop-app credentials for that project
- A local or network folder for the archive

## Setup

### 1. Configure Google OAuth

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable the **Gmail API**.
3. Configure the OAuth consent screen in **Google Auth Platform**. For ongoing personal use, use **In production** rather than **Testing**; testing-mode refresh tokens may expire after seven days.
4. Create an OAuth client of type **Desktop app** and download the client credentials.
5. Save the credentials in the format expected by the included `GmailOAuth.ps1` helper as `GmailOAuth.json`.
6. Run `GmailOAuth.ps1`, sign in to your Google account, and grant the requested permissions. The helper creates or updates `GmailToken.json`.

Google may display an **unverified app** warning for a personal, unverified OAuth application.

**Keep `GmailOAuth.json` and `GmailToken.json` private. Never commit them to GitHub.**

### 2. Configure the archive

Copy `Gmail_Archive_Settings.example.psd1` to `Gmail_Archive_Settings.psd1` and edit the values for your environment.

Some key settings:

| Setting | Description |
| --- | --- |
| `ArchiveRoot` | Destination folder for archived HTML files, attachments, and the log. |
| `ScriptFolder` | Folder containing the scripts and OAuth files. |
| `TriggerLabel` | Gmail label that selects conversations for archiving. |
| `OwnAddresses` | Your email addresses, omitted from participant names in filenames. |
| `MaxSubjectLength` | Maximum subject length in filenames. |
| `SaveAttachments` | Download and link attachments. |
| `DownloadImages` | Attempt to save external images locally. |
| `DryRun` | Test processing without exporting archive files. Logging may still occur. |
| `UpdateExisting` | Update archived conversations when their contents change. |
| `MaxThreads` | Maximum number of conversations to process per run. |
| `ApiRequestIntervalMs` | Delay between Gmail API requests. |
| `ApiRetryCount` | Retry limit for temporary API failures. |
| `LogSkipped` | Include skipped conversations in the HTML log. |
| `LogTitle` | Title displayed in the HTML log. |

Additional settings control filenames, API pacing, testing, progress reporting, and logging.

### 3. Run

Start the included `.cmd` file. It launches PowerShell with an execution-policy bypass **for that process only**; it does not change the system-wide execution policy.

For daily use, a shortcut to the batch file is recommended.

Review the HTML log in your archive folder after the run.

## Important notes

- **Back up your archive.** Do not treat the index file as a substitute for archived HTML files and attachments.
- The archiver itself does **not** delete Gmail messages. Any future Gmail deletion step must independently verify that the complete conversation and its attachments have been archived before deleting anything.
- Do not manually remove archived files without considering their entries in the archive index.
- The private settings file and all OAuth/token files should be excluded from version control; publish only the example settings file.

## Credits

Created by **John Halfords**.

Special thanks to **ChatGPT (OpenAI)** for development assistance.

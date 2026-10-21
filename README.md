* Gmail Archive — by John Halfords, the Netherlands        
<a href="https://github.com/JohnHalfords/Gmail_Archive">For download, go to the Github page...</a>
<br>

# Gmail Archive — by John Halfords

A Windows PowerShell 5.1 utility for creating an independent, browsable HTML archive of Gmail conversations, including attachments. An optional **separate** cleanup script can move fully verified messages to Gmail Trash.


## Features

1. **Archive entire conversations:** When at least one message in a conversation carries the configured trigger label (for example `ToArchive`), archive every message in that conversation.
2. **Include all conversation messages:** Include messages already in Gmail Trash when the conversation also has an eligible trigger-labeled message outside Trash.
3. **Evaluate labels across the conversation:** Collect labels from **all** messages, not just the last message.
4. **Support multiple archive folders:** If a conversation has multiple relevant user labels, make the complete archive available in each corresponding folder.
5. **Preserve conversation content:** Keep messages in chronological order, with attachments and locally saved images where available.
6. **Use real email participants:** Derive correspondent names from actual From/To/Cc headers, exclude configured own addresses, and separate multiple names with `, `.
7. **Avoid unnecessary rewrites:** Use the archive index to recognize existing content and extend archives when new messages appear.
8. **Preserve original identifiers:** Track Gmail message IDs and thread IDs in the index, including when conversations are merged into one archive.
9. **Keep the archive independently usable:** Save browsable HTML and assets on disk, so archived conversations can be viewed without Gmail.


## Requirements

- Windows PowerShell **5.1**.
- A Gmail account and a Google Cloud project with the Gmail API enabled.
- A writable local or network archive folder. A NAS/UNC destination is supported.


## Files and layout

```text
Gmail_Archive/
├── private/
│   ├── GmailOAuth.json
│   └── GmailToken.json
├── .gitignore
├── Gmail_Archive_Delete_v1.03.ps1
├── Gmail_Archive_OAuth_v1.00.ps1
├── Gmail_Archive_Settings.example.psd1
├── Gmail_Archive_Settings.psd1
├── Gmail_Archive_v1.00.ps1
├── README.md
├── Start_Gmail_Archive.cmd
├── Start_Gmail_Archive_Delete.cmd
└── Start_Gmail_OAuth.cmd
```

The archive destination (configured by `ArchiveRoot`) contains the HTML archives, assets, an `ArchiefIndex.json`, and the HTML log. It does **not** need to be the same folder as the scripts.


## Configuration

Copy `Gmail_Archive_Settings.example.psd1` to `Gmail_Archive_Settings.psd1`. Edit the copy for your paths, labels and Gmail addresses. Every setting is documented with an English comment in the example file.

Important settings:

| Setting | Purpose |
| --- | --- |
| `ScriptFolder` | Folder containing scripts, settings and `private/` |
| `ArchiveRoot` | Destination folder for the archive and index |
| `TriggerLabel` | Gmail label that selects conversations for archiving |
| `OwnAddresses` | Your email addresses, excluded from participant names |
| `MaxSubjectLength` | Configurable filename subject limit (default `35`) |
| `MaxThreads` | Maximum conversations to check in a single run |
| `DryRun` | Preview archive processing |
| `UpdateExisting` | Allow extending existing archived conversations |
| `SaveAttachments`, `DownloadImages` | Control offline asset preservation |
| `ApiRequestIntervalMs`, `ApiMinIntervalMs` | API pacing controls |
| `ApiRetryCount`, `ApiRetrySeconds` | API retry settings |
| `LogFile`, `MaxLogSizeMB` | HTML log location and retention size |


## OAuth setup

1. Create a Google Cloud project, enable the Gmail API, and create OAuth credentials for a desktop application.
2. Create a `private/` folder next to the scripts and save the downloaded OAuth credentials as `GmailOAuth.json` (or the filename specified in settings).
3. Run `Start_Gmail_OAuth.cmd` to authorize Gmail access.
4. The OAuth helper saves the authorization token as `private/GmailToken.json` (or the filename specified in settings).
5. Keep both JSON files **secret**; never share them.

Gmail Archive requires the `gmail.readonly` scope, while Gmail Archive Delete requires `gmail.modify`. The OAuth helper requests both scopes.

Access tokens are refreshed during long runs. The scripts read the OAuth files from `private/`.


## Optional: move verified messages to Gmail Trash

The Delete script is intentionally separate. It checks the current Gmail message IDs against the archive index **per conversation**. If there is any discrepancy, the entire conversation is blocked. For eligible conversations, it uses individual `messages.trash` operations, **not** `threads.trash`, and requires confirmation before making Gmail changes. It never deletes local archive files. **Trash is not permanent deletion**, but emptying Gmail Trash later is permanent; verify your archive first.


## Run

Simply double-click the appropriate `.cmd` file:

- **`Start_Gmail_OAuth.cmd`** – Set up Gmail authorization (first-time setup).
- **`Start_Gmail_Archive.cmd`** – Archive Gmail conversations.
- **`Start_Gmail_Archive_Delete.cmd`** – Move verified archived messages to Gmail Trash.

The `.cmd` files are the **recommended way** to run Gmail Archive on Windows. They automatically start the corresponding PowerShell scripts from the correct directory.
PowerShell's execution policy is temporarily bypassed **only for the launched PowerShell process**. Your system's execution policy remains unchanged.

Start with `DryRun = $true` when validating paths and label selection. Inspect the generated archive and `ArchiefIndex.json` after a real run before considering deletion.

**Archiving never moves, deletes, or changes Gmail messages.** It writes files to the configured archive destination.


## Operational notes

- Gmail API rate limits can interrupt a run. The scripts pace requests and retry qualifying transient failures, but cannot guarantee uninterrupted operation or a particular throughput.
- `MaxThreads` can stop a run before all matching conversations are checked; increase it for larger mailboxes.
- External images and some unusual message content may not be available offline; check warnings in the HTML log.
- Keep independent backups of your archive and index before using the Delete script.
- Archive/index behavior should be verified with your own test messages before production use.


## Disclaimer

This software is provided "as is", without warranty of any kind.
Use it at your own risk. I am not responsible for any data loss, damage, or other consequences resulting from its use.
Always - Always - Always verify your archives and keep backups before deleting Gmail messages.

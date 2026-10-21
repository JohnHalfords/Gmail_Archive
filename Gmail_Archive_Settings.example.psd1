# Example configuration: copy to Gmail_Archive_Settings.psd1 and edit locally.
# Shared configuration for Gmail Archive, Gmail Archive Delete, and Gmail Archive OAuth.
# OAuth JSON files must be placed in the private/ subfolder.
# HTML log title is fixed: Gmail Archive - by John Halfords.
# Gmail History sync is intentionally not used; every run checks labeled threads.

@{
    # Folder containing the scripts, settings file and private/ directory.
    ScriptFolder       = 'C:\Gmail_Archive'
    # OAuth client JSON filename, located in ScriptFolder\private.
    OAuthFile          = 'GmailOAuth.json'
    # OAuth token JSON filename, located in ScriptFolder\private.
    TokenFile          = 'GmailToken.json'
    # A thread is selected when at least one message has this Gmail label.
    TriggerLabel       = 'ToArchive'
    # Destination root for archived HTML, attachments and ArchiefIndex.json.
    ArchiveRoot        = 'D:\GmailArchive'
    # Destination subfolder when no other relevant user labels are found.
    NoLabelFolder      = 'NoGmailLabel'
    # Maximum subject length used in generated filenames.
    MaxSubjectLength   = 35
    # Maximum participant-name length in generated filenames.
    MaxSenderLength    = 60
    # Maximum filename length for saved attachments.
    MaxAttachmentLength = 70
    # Preview archive processing without writing new archived conversations.
    DryRun             = $false
    # Maximum number of unique Gmail threads to process per run; raise for full scans.
    MaxThreads         = 2000
    # Minimum pause between requests; Delete enforces at least 1500 ms.
    ApiRequestIntervalMs = 1500
    # Maximum number of retries for transient Gmail API errors.
    ApiRetryCount      = 5
    # Initial retry delay for archive API calls (exponential for transient failures).
    ApiRetrySeconds    = 1
    # Additional spacing for expensive archive requests, in milliseconds.
    ApiMinIntervalMs   = 3000
    # Progress display percentage step; 0 disables progress output.
    ProgressEvery      = 1
    # Extend existing archived conversations when new messages appear.
    UpdateExisting     = $true
    # Save message attachments alongside HTML archives.
    SaveAttachments    = $true
    # Download external/inline images where possible for offline reading.
    DownloadImages     = $true
    # Subdirectory for saved assets belonging to an HTML archive.
    FilesFolder        = 'files'
    # HTML log filename under ArchiveRoot.
    LogFile            = '_Gmail_Archive.html'
    # Your own addresses, excluded from correspondent names.
    OwnAddresses       = @('your.address@gmail.com')
    # Maximum HTML log size; older complete runs are removed first.
    MaxLogSizeMB       = 2
    # Include errors in the HTML log.
    LogErrors          = $true
    # Include warnings in the HTML log.
    LogWarnings        = $true
    # Include warnings for images that cannot be downloaded.
    LogImageWarnings   = $false
    # Include skipped conversations in the HTML log.
    LogSkipped         = $true
    # Include newly archived conversations in the HTML log.
    LogNewThreads      = $true
    # Include updated conversations in the HTML log.
    LogUpdatedThreads  = $true
    # Write an HTML log when running in DryRun mode.
    LogDryRuns         = $true
}

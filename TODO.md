Known issue:

- Understand naming convention about actor usage (e.g. Merge FTPClient with FtpClientActor, remove the suffix, etc…
- Have a timeout when receiving data on data channels
- Still doesn't really work with folders, can wait.
- No transfer entry in the transfer pane
- To test once the download speed has been improved: Finder completion status icon
- Create tests for the Ferri app (trying to understand how to make that work with no access to docker CLI in tests [App Sandbox])
- Use VSplitView instead of VStack for the transfer/file browser division
- Clicking the refresh button move us back to the root folder
- Double click on a folder doesn't open it
- No "selection" of file (e.g. click on file doesn't change its background to blue/text to white)
- Make sure we have a test for download integrity (e.g. file on server has same hash as file downloaded)

- AGENTS.md file.
    - Add "use xcode MCP over any CLI tool whenever you have the chance"
        - Super useful to avoid issue with swift packages
    - Also add the scope of the project
        - not a full fledge FTP server, only one use for browsing/download.
        - No support for operations that modify remote objects)


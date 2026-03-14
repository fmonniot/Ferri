Known issue:

- ~Modifying an existing connection doesn't really work. Existing value aren't show, and so it gives the impression to start from scratch again.~
    Fixed by pickle when adding new insecure toggle
- Fix all the issues reported by xcode
- There are some thread issue with the network code, need to fix that (especially given it's the main reason I'm leaving cyberduck for)
- Understand naming convention about actor usage (e.g. Merge FTPClient with FtpClientActor, remove the suffix, etc…
- Have a timeout when receiving data on data channels


- AGENTS.md file.
    - Add "use xcode MCP over any CLI tool whenever you have the chance"
        - Super useful to avoid issue with swift packages
    - Also add the scope of the project
        - not a full fledge FTP server, only one use for browsing/download.
        - No support for operations that modify remote objects)


Run unit tests from the CLI: `xcodebuild test -scheme iFTP -only-testing:iFTPUnitTests/`

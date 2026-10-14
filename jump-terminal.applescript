-- Select the Terminal.app tab running on /dev/<tty>.
on run argv
    set ttyName to "/dev/" & item 1 of argv
    tell application "Terminal"
        activate
        repeat with win in windows
            repeat with tb in tabs of win
                if tty of tb is ttyName then
                    set selected tab of win to tb
                    set index of win to 1
                    return "selected " & ttyName
                end if
            end repeat
        end repeat
    end tell
    return "no tab on " & ttyName
end run

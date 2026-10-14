-- Select the iTerm2 session running on /dev/<tty>.
on run argv
    set ttyName to "/dev/" & item 1 of argv
    tell application "iTerm2"
        activate
        repeat with win in windows
            repeat with tb in tabs of win
                repeat with ss in sessions of tb
                    if tty of ss is ttyName then
                        select win
                        select tb
                        select ss
                        return "selected " & ttyName
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return "no session on " & ttyName
end run

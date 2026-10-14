// Each VS Code window listens on a random local port and writes it to ~/.claude-waiting/vscode/<port>.
// The widget asks every port "focus tty X"; the window that owns that terminal answers 200 with its folder.
const vscode = require('vscode')
const http = require('http')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFileSync, execFile } = require('child_process')

const DIR = path.join(os.homedir(), '.claude-waiting', 'vscode')
let server
let portFile

const ttyOf = (pid) => {
    try { return execFileSync('/bin/ps', ['-o', 'tty=', '-p', String(pid)]).toString().trim() } catch { return '' }
}

const focusTty = async (tty) => {
    for (const terminal of vscode.window.terminals) {
        const pid = await terminal.processId
        if (pid && ttyOf(pid) === tty) {
            terminal.show(false)
            // Re-opening our own folder raises this window; done from here so the widget needs no file access.
            const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath
            execFile('/usr/bin/open', folder ? ['-b', 'com.microsoft.VSCode', folder] : ['-b', 'com.microsoft.VSCode'])
            return true
        }
    }
    return false
}

exports.activate = () => {
    fs.mkdirSync(DIR, { recursive: true })
    server = http.createServer((req, res) => {
        const url = new URL(req.url, 'http://localhost')
        const tty = url.searchParams.get('tty')
        if (url.pathname !== '/focus' || !tty) { res.writeHead(404); res.end(); return }
        focusTty(tty).then((ok) => {
            res.writeHead(ok ? 200 : 404)
            res.end(ok ? (vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? '') : '')
        })
    })
    server.listen(0, '127.0.0.1', () => {
        portFile = path.join(DIR, String(server.address().port))
        fs.writeFileSync(portFile, String(process.pid))
    })
}

exports.deactivate = () => {
    try { fs.unlinkSync(portFile) } catch {}
    server?.close()
}

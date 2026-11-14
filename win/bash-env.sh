# bash-env.sh: the lab's setup for Git Bash on the Windows VM, at C:\vmlab\bash-env.sh. Every
# bash of an SSH session reads it: a command through ~/.bashrc (a shell that sshd starts reads
# that one), a terminal through ~/.bash_profile and ~/.bashrc, a script on stdin and the shells
# within through BASH_ENV, which vmshell sets. desktop-ssh.ps1 puts it in place.

# fnm switches Node versions through `fnm env`, which each shell has to evaluate before `fnm use`.
# It runs at the first fnm command, not in every shell. Then `fnm use system`, as in the
# PowerShell profile: fnm makes the first version installed its default, and Node 26 stays the
# Node of every shell until a command asks for another.
fnm() {
  if [ -z "${FNM_MULTISHELL_PATH:-}" ]; then
    eval "$(command fnm env --shell bash)" || return
    command fnm use system > /dev/null 2>&1
  fi
  command fnm "$@"
}

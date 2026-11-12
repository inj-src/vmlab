# states.sh: what a VM's named states have in common. Sourced by win3d/win-venus.sh and
# reims/mac26.sh, which set STATES (a folder under /vmlab/images/states) and ST_VM (the VM's name
# in `vm`), and have die().
#
# A state is the whole disk as it was at `vm save`. Where the disk is kept differs (Windows: a
# file of the changes since the ready state; Mac: a snapshot inside its one disk file), so
# save, load, rm and list are the launchers' own. Here: the names, the notes, and two marks
# that say what the working disk holds now:
#   .current   the state it was last loaded from or saved as ("clean" where the file is absent)
#   .changed   it has run since
# The marks guard one thing: replacing a disk that ran on a named state and was not saved
# since. A run on the clean state is dropped without a question, as `reset` always did.

st_valid(){
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,15}$ && $1 != clean ]] ||
    die "a state's name is up to 16 lower-case letters, digits and . _ - (and not 'clean'): '$1'"
}
st_current(){ cat "$STATES/.current" 2>/dev/null || echo clean; }
st_changed(){ [[ -e $STATES/.changed ]]; }
st_mark(){ mkdir -p "$STATES"; echo "$1" > "$STATES/.current"; rm -f "$STATES/.changed"; }  # the disk is this state as saved
st_ran(){ mkdir -p "$STATES"; : > "$STATES/.changed"; }                                    # every start
st_guard(){   # st_guard [--discard]: before the working disk is replaced
  local cur; cur=$(st_current)
  [[ $cur == clean || ${1:-} == --discard ]] && return 0
  st_changed || return 0
  die "$ST_VM ran on the state '$cur' and was not saved since. 'vm save $ST_VM $cur --replace' keeps that; 'vm reset $ST_VM --discard' drops it"
}
st_forget(){  # a deleted state is nobody's current one: a disk still holding it is "clean and changed"
  rm -f "$STATES/$1.note"
  [[ $(st_current) != "$1" ]] || { echo clean > "$STATES/.current"; : > "$STATES/.changed"; }
}

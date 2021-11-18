#!/usr/bin/env bash
set -x

#Requirements:
    #Local+Remote: ffmpeg,openssh,netevent-git
    #Local: inotify-tools
    #read/write access to input devices on local and remote system (input group) (sudo gpasswd --add username input)

#Remote host
    RHOST="" # Remote ip or hostname
    RPORT="22"             # Remote ssh port to connect to
    RUSER=""               # The user on the remote side running the real X server
    EVDFILE="$HOME/.config/ssh-rdp.input.evd.config"  #Holds the name of the forwarded evdev device
    KBDFILE="$HOME/.config/ssh-rdp.input.kbd.config"  #Holds the name of the forwarded keyboard evdev device
    HKFILE="$HOME/.config/ssh-rdp.input.hk.config"    #where the keypress codes to switch fullscreen and forward reside


# Misc
    SSH_CIPHER="" #Optionally, force an ssh cipher to be used
    #SSH_CIPHER="aes256-gcm@openssh.com"


# ### User config ends here ### #

ICFILE_RUNTIME=~/.config/ssh-rdp.input.out.config

print_error()   { echo -e "\e[1m\e[91m[EE] $1\e[0m" ;};
print_warning() { echo -e "\e[1m\e[93m[WW] $1\e[0m" ;};
print_notice()  { echo -e "\e[1m[!!] $1\e[0m" ;};
print_ok()      { echo -e "\e[1m\e[92m[OK] $1\e[0m" ;};
print_pending() { echo -e "\e[1m\e[94m[..] $1\e[0m" ;};

ask_continue_or_exit(){
    while true; do
        read -p "$(print_warning "Do you want to continue anyway (not recommended) (y/n) ? ")" yn
        case $yn in
            [Yy]* ) ERROR=0; break;;
            [Nn]* ) ERROR=1; break;;
            * ) print_error "Please answer y or n.";;
        esac
    done
    if [ "$ERROR" = "1" ] ; then
        print_error "Cannot continue."
        exit
            else
        print_warning "Proceeding anyway..."
    fi
}

generate_ICFILE_from_names() {
    #Also, exits from the script if no keyboard is found
    I_IFS="$IFS"
    IFS=$'\n' ;
    ICFILE_REJ=~/.config/ssh-rdp.input.rej.txt

    rm $ICFILE_RUNTIME $ICFILE_REJ &>/dev/null
    ERROR="0"
    print_pending "Checking input devices..."
    for device_name in $(<$EVDFILE) ; do
        evdev_devices=$(events_from_name "$device_name")
        if [ "$evdev_devices" = "" ] ; then
            print_warning "Device unavailable : $device_name"
                else
            print_ok "Device ready       : $device_name"
            for evdevice in $evdev_devices ; do
                echo "     add event device for $device_name: $evdevice"
                echo -n $evdevice" " >> "$ICFILE_RUNTIME"
            done
        fi
    done
    IFS="$I_IFS"
    print_pending "Reading hotkey file $HKFILE"
    read GRAB_HOTKEY FULLSCREENSWITCH_HOTKEY <<< $(<$HKFILE)
    print_ok "GRAB_HOTKEY=$GRAB_HOTKEY"
}

name_from_event(){
    #es: name_from_event event3 
    #Logitech G203 Prodigy Gaming Mouse
    grep 'Name=\|Handlers' /proc/bus/input/devices|grep -B1 "$1"|head -n 1|cut -d \" -f 2
}

events_from_name(){
    #es: vents_from_name Logitech G203 Prodigy Gaming Mouse
    #event13
    #event2
    grep 'Name=\|Handlers' /proc/bus/input/devices|grep -A1 "$1"|cut -d "=" -f 2 |grep -o '[^ ]*event[^ ]*'
}

check_local_input_group(){
    if ! id -nG $(id -u)|grep -qw input  ; then 
        echo
        print_warning "local user is not in the input group,"
        print_warning "but /dev/input/* access is required to forward input devices."
        ask_continue_or_exit
    fi
}

check_remote_uinput_access(){
	$SSH_EXEC "test -w /dev/uinput" || E="noaccess"
	$SSH_EXEC "test -r /dev/uinput" || E="noaccess"
	
    if [ "$E" = "noaccess" ] ; then
        echo
        print_warning "Remote user is missing R/W access to /dev/uinput"
        print_warning "which is needed to forward input devices."
        ask_continue_or_exit
    fi
}

create_input_files() {
    check_local_input_group
    tmpfile=/tmp/$$devices$$.txt
    sleep 0.1
    timeout=10 #seconds to probe for input devices
    cd /dev/input/

    #Ask user to generate input to auto select input devices to forward
    echo Please, generate input on devices you want to forward, keyboard is mandatory!
    rm $tmpfile &>/dev/null
    for d in event* ; do 
        sh -c "timeout 10 grep . $d -m 1 -c -H |cut -d ":" -f 1 |tee -a $tmpfile &" 
    done 
    echo Waiting 10 seconds for user input...
    sleep $timeout
    list=""
    #Make a list of device names
    rm $EVDFILE &>/dev/null
    for evdevice in $(<$tmpfile) ; do 
        name=$(name_from_event $evdevice|tr " " ".")
        list="$list $name $evdevice off "
        echo $(name_from_event $evdevice)  >> $EVDFILE
    done
    #ask user to select the keyboard device
    echo
    echo "Press a key on the keyboard which will be forwarded."
    KBDDEV=$(inotifywait event* -q | cut -d " " -f 1)
    echo "Got $(name_from_event $KBDDEV)"
    name_from_event $KBDDEV > $KBDFILE

    # create_hk_file
    # uses netevent to generate a file containing the key codes
    # to switch fullscreen and forward devices
        cd /dev/input
        rm $HKFILE &>/dev/null
        sleep 1
        echo ; echo Press the key to forward/unforward input devices
        GRAB_HOTKEY=$(netevent show $KBDDEV 3 -g | grep KEY |cut -d ":" -f 2) ; echo got:$GRAB_HOTKEY
        sleep 0.5
        echo ; echo Press the key to switch fullscreen state

        echo
        echo GRAB_HOTKEY=$GRAB_HOTKEY

    rm $tmpfile
}

list_descendants() {
    local children=$(ps -o pid= --ppid "$1")
    for pid in $children ; do
        list_descendants "$pid"
    done
    echo "$children"
}

#Clean function
finish() {
    #echo ; echo TRAP: finish.

    if ! [ "$REXEC_EXIT" = "" ] ; then
        print_pending "Executing $REXEC_EXIT"
        $SSH_EXEC "bash -s" < "$REXEC_EXIT"
        print_ok "$REXEC_EXIT exited."
    fi
  sleep 1
    ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" $RHOST 2>/dev/null
    kill $(list_descendants $$) &>/dev/null
    
    rm $NESCRIPT &>/dev/null
    rm $NE_CMD_SOCK&>/dev/null
    
}

#Test and report net download speed
benchmark_net() {
    $SSH_EXEC sh -c '"timeout 1 dd if=/dev/zero bs=1b "' | cat - > /tmp/zero
    KBPS=$(( $(wc -c < /tmp/zero) *8/1000   ))
    echo $KBPS
}

FS="F"
setup_input_loop() {    
    #Parse remote hotkeys and perform local actions (eg: Fullscreen switching)
    print_pending "Setting up input loop and forwarding devices"
    #Prepare netevent script
    i=1
    touch $NESCRIPT
    KBDNAME=$(<$KBDFILE)
    for DEVICE in $(<$ICFILE_RUNTIME) ; do
        echo "     forward input from device $DEVICE..."
        DEVNAME=$(name_from_event "$DEVICE")
        if  [ "$DEVNAME" = "$KBDNAME" ] ; then 
            echo "device add mykbd$i /dev/input/$DEVICE"  >>$NESCRIPT
            echo "hotkey add mykbd$i key:$GRAB_HOTKEY:1 grab toggle" >>$NESCRIPT
            echo "hotkey add mykbd$i key:$GRAB_HOTKEY:0 nop" >>$NESCRIPT
                else
            echo "device add dev$i /dev/input/$DEVICE"  >>$NESCRIPT
        fi
        let i=i+1
    done
    echo "output add myremote exec:$SSH_EXEC netevent create" >>$NESCRIPT
    echo "use myremote" >>$NESCRIPT

    echo 
    print_pending "Starting netevent daemon with script $NESCRIPT"
    netevent daemon -s $NESCRIPT $NE_CMD_SOCK | while read -r hotkey; do
        echo "read hotkey: " $hotkey
    done
}


deps_or_exit(){
    #Check that dependancies are ok, or exits the script
    check_local_input_group
    check_remote_uinput_access
    DEPS_L="bash grep head cut timeout sleep tee inotifywait netevent wc awk basename ssh  ["
    DEPS_OPT_L=""
    DEPS_R="bash timeout dd grep awk tail netevent"

    #Local deps
    for d in $DEPS_L ; do
        ERROR=0
        if ! which $d &>/dev/null ; then
            print_error "Cannot find required local executable: $d"
            ask_continue_or_exit
        fi
    done
    for d in $DEPS_OPT_L ; do
        if ! which $d &>/dev/null ; then
            print_warning "Cannot find required optional executable: $d"
        fi
    done

    #Remote deps
    for d in $DEPS_R ; do
        ERROR=0
        if ! $SSH_EXEC "which $d &>/dev/null" ; then
            print_error "Cannot find required remote executable: $d"
            ask_continue_or_exit
        fi
    done
}


# ### MAIN ### ### MAIN ### ### MAIN ### ### MAIN ###

if [ "$1 " = "inputconfig " ] ; then
    create_input_files
    exit
fi

#Parse arguments
while [[ $# -gt 0 ]]
do
    arg="$1"
    case $arg in
        -u|--user)
            RUSER="$2"
            shift ; shift ;;
        -s|--server)
            RHOST="$2"
            shift ; shift ;;
        -p|--port)
            RPORT="$2"
            shift ; shift ;;
        --follow)
			FOLLOW_STRING='-follow_mouse 1'
            shift ;;
        --rexec-before)
            REXEC_BEFORE="$2"
            shift ; shift ;;
        --rexec-exit)
            REXEC_EXIT="$2"
            shift ; shift ;;
        *)
            shift ;;
    esac
done
    
    
#Sanity check

    me=$(basename "$0")
    if [ -z $RUSER ] || [ -z $RHOST ] || [ "$1" = "-h" ] ; then
        echo Please edit "$me" to suid your needs and/or use the following options:
        echo Usage: "$me" "[OPTIONS]"
        echo ""
        echo "OPTIONS"
        echo ""
        echo "Use $me inputconfig to create or change the input config file"
        echo ""
        echo "-s, --server        Remote host to connect to"
        echo "-u, --user          ssh username"
        echo "-p, --port          ssh port"
        echo "    --rexec-before  Execute the specified script via 'sh' just before the connection"
        echo "    --rexec-exit    Execute the specified script via 'sh' before exiting the script"
        echo 
        echo "user and host are mandatory."
        echo "default ssh-port: $RPORT"
        exit
    fi
    
    if [ ! -f "$EVDFILE" ] ; then
        print_error "Input configuration file "$EVDFILE" not found!"
        echo "Please, Select which devices to share."
        sleep 2
        create_input_files
    fi

trap finish INT TERM EXIT
    
#Setup SSH Multiplexing
    SSH_CONTROL_PATH=$HOME/.config/ssh-rdp$$
    print_pending "Starting ssh multiplexed connection"
    if ssh -fN -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH -o ControlPersist=60 $RUSER@$RHOST -p $RPORT ; then
        print_ok "Started ssh multiplexed connection"
            else
        print_warning "Cannot start ssh multiplexed connection"
        ask_continue_or_exit
    fi
#Shortcut to start remote commands:
    [ ! "$SSH_CIPHER" = "" ] && SSH_CIPHER=" -c $SSH_CIPHER"
    SSH_EXEC="ssh $SSH_CIPHER -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH $RUSER@$RHOST -p $RPORT"

print_pending "Checking required executables..."
deps_or_exit
print_ok "Checked required executables"
echo

generate_ICFILE_from_names

#netevent script file and command sock
    NESCRIPT=/tmp/nescript$$
    NE_CMD_SOCK=/tmp/neteventcommandsock$$

echo

if ! [ "$REXEC_BEFORE" = "" ] ; then
    print_pending "Executing $REXEC_BEFORE"
    $SSH_EXEC "bash -s" < "$REXEC_BEFORE"
    print_ok "$REXEC_BEFORE exited."
fi

setup_input_loop & 
sleep 0.1 #(just to not shuffle output messages)
PID1=$!
sleep 100000

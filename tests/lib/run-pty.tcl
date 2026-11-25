# Run an exact argument array under a real PTY on Linux and macOS.
set timeout 30
spawn -noecho {*}$argv
expect {
	eof {}
	timeout { exit 124 }
}
set status [wait]
if {[lindex $status 2] != 0 || [llength $status] != 4} { exit 125 }
exit [lindex $status 3]

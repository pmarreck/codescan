# Copyright (c) 2026 Peter Marreck. MIT License; see LICENSE.
# Text-only test capture, adapted from capture's RAM-only descriptor protocol.
# Command substitutions intentionally strip trailing newlines, as before.
capture() {
	local captured_stdout captured_stderr captured_status
	source <(
		{
			captured_stderr=$(
				{
					if captured_stdout=$("$@" 2>&3); then
						captured_status=0
					else
						captured_status="$?"
					fi
					declare -p captured_stdout captured_status >&4
				} 3>&1
			)
			declare -p captured_stderr >&4
		} 4>&1
	)
	out="$captured_stdout"
	err="$captured_stderr"
	rc="$captured_status"
}

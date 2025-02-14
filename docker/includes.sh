# Did you know these color nomenclatures are from Delphi (Object Pascal) ? :)
cl_error="\u001b[91m"
cl_status="\u001b[94m"
cl_info="\u001b[93m"
cl_reset="\u001b[0m"
cl_gray="\u001b[90m"
cl_success="\u001b[92m"
cl_cyan="\e[36m"

# Information is power.
cPrint() {
    local now
    local color="$1"
    local message="$2"
          now=$(date "+%d/%m/%Y %H:%M:%S")
    case "$color" in
        status)
            echo -e "${cl_status}[$now - STATUS]: ${cl_reset}${message}"
            ;;
        info)
            echo -e "${cl_info}[$now - INFO]: ${cl_reset}${message}"
            ;;
        error)
            echo -e "${cl_error}[$now - ERROR]: ${cl_reset}${message}"
            ;;
        success)
          echo -e "${cl_success}[$now - SUCCESS]: ${message}${cl_reset}"
          ;;
        *)
            echo -e "$cl_status [$now]:$cl_reset $message"
            ;;
    esac
}

# A Horizontal line.
printHr(){
  echo -e "$cl_gray=================================================================================================================================================$cl_reset"
}
function nvc
    set -l claude_args ""
    set -l env_vars

    # Capture environment variable assignments (VAR=value)
    while test (count $argv) -gt 0
        if string match -qr '^[A-Z_]+=.*' -- $argv[1]; and not string match -q -- '--*' $argv[1]
            set -a env_vars $argv[1]
            set argv $argv[2..-1]
        else
            break
        end
    end

    # Capture Claude flags
    while test (count $argv) -gt 0
        switch $argv[1]
            case '-*'
                switch $argv[1]
                    case --model --allowedTools --disallowedTools --permission-mode --max-turns
                        set claude_args "$claude_args $argv[1] $argv[2]"
                        set argv $argv[3..-1]
                    case '*'
                        set claude_args "$claude_args $argv[1]"
                        set argv $argv[2..-1]
                end
            case '*'
                break
        end
    end

    # Export env vars and run nvim with CLAUDE_ARGS
    for var in $env_vars
        set -l name (string split -m1 '=' $var)[1]
        set -l value (string split -m1 '=' $var)[2]
        set -gx $name $value
    end
    set -gx CLAUDE_ARGS "$claude_args"
    nvim $argv
end

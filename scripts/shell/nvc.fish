function nvc
    set -l claude_args ""
    while test (count $argv) -gt 0
        switch $argv[1]
            case '-*'
                switch $argv[1]
                    case --model --allowedTools --disallowedTools
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
    CLAUDE_ARGS="$claude_args" nvim $argv
end

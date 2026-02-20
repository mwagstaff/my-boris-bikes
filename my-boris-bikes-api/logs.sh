#!/bin/bash
# Log viewing helper script

LOG_DIR="logs"
TODAY=$(date +%Y-%m-%d)

case "$1" in
  tail|t)
    # Tail today's server logs
    tail -f "$LOG_DIR/server-$TODAY.log"
    ;;

  error|e)
    # Tail today's error logs
    tail -f "$LOG_DIR/error-$TODAY.log"
    ;;

  search|s)
    # Search all logs for a pattern
    if [ -z "$2" ]; then
      echo "Usage: $0 search <pattern>"
      exit 1
    fi
    grep -i "$2" "$LOG_DIR"/server-*.log
    ;;

  list|ls)
    # List all log files
    ls -lh "$LOG_DIR"
    ;;

  clean)
    # Remove old log files (older than 7 days)
    find "$LOG_DIR" -name "*.log" -mtime +7 -delete
    echo "Deleted logs older than 7 days"
    ;;

  *)
    echo "Log viewer for My Boris Bikes Live Activity Server"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  tail, t        - Tail today's server logs"
    echo "  error, e       - Tail today's error logs"
    echo "  search, s      - Search logs for a pattern"
    echo "  list, ls       - List all log files"
    echo "  clean          - Remove logs older than 7 days"
    echo ""
    echo "Examples:"
    echo "  $0 tail                    # Watch live logs"
    echo "  $0 error                   # Watch live error logs"
    echo "  $0 search BikePoints_316   # Search for dock ID"
    echo "  $0 search 'Session expired' # Search for expired sessions"
    exit 1
    ;;
esac

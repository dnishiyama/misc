#!/bin/bash
#
# Git Author Rewrite Script
# Rewrites the author and committer information for recent commits
#
# Usage:
#   ./rewrite-author.sh --name "Your Name" --email "your@email.com" --commits 15
#
# Options:
#   --name       Author/Committer name (required)
#   --email      Author/Committer email (required)
#   --commits    Number of commits to rewrite from HEAD (required)
#   -h, --help   Show this help message
#
# Examples:
#   ./rewrite-author.sh --name "John Doe" --email "john@example.com" --commits 10
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AUTHOR_NAME=""
AUTHOR_EMAIL=""
NUM_COMMITS=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            AUTHOR_NAME="$2"
            shift 2
            ;;
        --email)
            AUTHOR_EMAIL="$2"
            shift 2
            ;;
        --commits)
            NUM_COMMITS="$2"
            shift 2
            ;;
        -h|--help)
            head -20 "$0" | tail -17
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$AUTHOR_NAME" ]]; then
    echo -e "${RED}Error: --name is required${NC}"
    echo "Usage: $0 --name \"Your Name\" --email \"your@email.com\" --commits 15"
    exit 1
fi

if [[ -z "$AUTHOR_EMAIL" ]]; then
    echo -e "${RED}Error: --email is required${NC}"
    echo "Usage: $0 --name \"Your Name\" --email \"your@email.com\" --commits 15"
    exit 1
fi

if [[ -z "$NUM_COMMITS" ]]; then
    echo -e "${RED}Error: --commits is required${NC}"
    echo "Usage: $0 --name \"Your Name\" --email \"your@email.com\" --commits 15"
    exit 1
fi

# Validate NUM_COMMITS is a number
if ! [[ "$NUM_COMMITS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: --commits must be a positive integer${NC}"
    exit 1
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not in a git repository${NC}"
    exit 1
fi

# Show summary
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}               GIT AUTHOR REWRITE${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "Name:     ${GREEN}$AUTHOR_NAME${NC}"
echo -e "Email:    ${GREEN}$AUTHOR_EMAIL${NC}"
echo -e "Commits:  ${GREEN}Last $NUM_COMMITS commits${NC}"
echo -e "Range:    ${GREEN}HEAD~${NUM_COMMITS}..HEAD${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${RED}⚠️  WARNING: This will rewrite git history!${NC}"
echo -e "${RED}   If you've already pushed these commits, you'll need to force push.${NC}"
echo ""

# Confirm
read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}Rewriting commit history...${NC}"

# Run git filter-branch
git filter-branch --force --env-filter "
CORRECT_NAME=\"$AUTHOR_NAME\"
CORRECT_EMAIL=\"$AUTHOR_EMAIL\"

export GIT_COMMITTER_NAME=\"\$CORRECT_NAME\"
export GIT_COMMITTER_EMAIL=\"\$CORRECT_EMAIL\"
export GIT_AUTHOR_NAME=\"\$CORRECT_NAME\"
export GIT_AUTHOR_EMAIL=\"\$CORRECT_EMAIL\"
" HEAD~${NUM_COMMITS}..HEAD

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           REWRITE COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review the changes: ${BLUE}git log --pretty=format:'%h %an <%ae> %s'${NC}"
echo -e "  2. If you've already pushed, force push: ${BLUE}git push --force${NC}"
echo ""
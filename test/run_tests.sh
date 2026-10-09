#!/usr/bin/env bash
# aicommit Test Runner
# Executes all test suites and generates comprehensive reports

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test categories
TEST_CATEGORIES=(
    "smoke"
    "unit"
    "negative"
    "edge"
    "security"
    "exception"
    "regression"
    "compliance"
    "integration"
)

# Results tracking
declare -A TEST_RESULTS
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

check_dependencies() {
    print_header "Checking Dependencies"
    
    # Check for BATS
    if ! command -v bats &> /dev/null; then
        print_error "BATS not installed. Installing..."
        git clone https://github.com/bats-core/bats-core.git
        sudo bats-core/install.sh /usr/local
        print_success "BATS installed successfully"
    else
        print_success "BATS is available"
    fi
    
    # Check for git
    if ! command -v git &> /dev/null; then
        print_error "Git not installed"
        exit 1
    else
        print_success "Git is available"
    fi
    
    echo
}

run_test_category() {
    local category="$1"
    # unit stays as a directory; all others are flat files under test/contexts/
    local test_path
    if [ -d "test/$category" ]; then
        test_path="test/$category"
    elif [ -f "test/contexts/${category}.bats" ]; then
        test_path="test/contexts/${category}.bats"
    else
        print_warning "Test category '$category' not found"
        return 1
    fi

    print_header "Running $category Tests"

    # Run tests and capture results
    local output_file="/tmp/test-${category}-$RANDOM.log"

    if bats --formatter tap "$test_path" > "$output_file" 2>&1; then
        TEST_RESULTS["$category"]="PASS"
        print_success "$category tests passed"
    else
        TEST_RESULTS["$category"]="FAIL"
        print_error "$category tests failed"
    fi
    
    # Count tests
    local category_total category_passed category_failed
    category_total=$(grep -c "^ok" "$output_file" || true)
    category_passed=$(grep -c "^ok" "$output_file" || true)
    category_failed=$(grep -c "^not ok" "$output_file" || true)
    
    TOTAL_TESTS=$((TOTAL_TESTS + category_total))
    PASSED_TESTS=$((PASSED_TESTS + category_passed))
    FAILED_TESTS=$((FAILED_TESTS + category_failed))
    
    # Show detailed results
    echo "Results: $category_passed/$category_total passed"
    echo
    
    rm -f "$output_file"
}

generate_report() {
    print_header "Test Summary Report"
    
    echo "Test Categories Results:"
    for category in "${TEST_CATEGORIES[@]}"; do
        local result="${TEST_RESULTS[$category]:-SKIP}"
        local status_icon
        
        case "$result" in
            "PASS") status_icon="✅" ;;
            "FAIL") status_icon="❌" ;;
            "SKIP") status_icon="⏭️" ;;
            *) status_icon="❓" ;;
        esac
        
        printf "%-15s: %s %s\n" "$category" "$status_icon" "$result"
    done
    
    echo
    echo "Overall Statistics:"
    echo "Total Tests: $TOTAL_TESTS"
    echo "Passed: $PASSED_TESTS"
    echo "Failed: $FAILED_TESTS"
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}All tests passed! 🎉${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed. Please check the output above.${NC}"
        return 1
    fi
}

run_security_scan() {
    print_header "Running Security Scan"

    local found_issue=false

    # Prefer gitleaks for actual secret detection (scans current files only)
    if command -v gitleaks >/dev/null 2>&1; then
        if gitleaks detect --source . --no-git --no-banner >/dev/null 2>&1; then
            print_success "gitleaks found no hardcoded secrets in current files"
        else
            print_error "gitleaks detected potential secrets in current files"
            gitleaks detect --source . --no-git --no-banner || true
            found_issue=true
        fi
    else
        print_warning "gitleaks not installed; skipping secret scan"
        echo "Install with: brew install gitleaks  (or equivalent)"
    fi

    if command -v trivy >/dev/null 2>&1; then
        if trivy fs --scanners secret --no-progress --quiet . >/dev/null 2>&1; then
            print_success "trivy found no filesystem secrets"
        else
            print_error "trivy detected potential filesystem secrets"
            trivy fs --scanners secret --no-progress . || true
            found_issue=true
        fi
    fi

    # Check for unsafe permissions
    if find . -name "*.sh" -perm /o+w ! -path './test/*' 2>/dev/null | grep -q .; then
        print_warning "World-writable shell scripts found"
        found_issue=true
    else
        print_success "Shell scripts have appropriate permissions"
    fi

    if [ "$found_issue" = true ]; then
        return 1
    fi

    echo
}

cleanup_test_artifacts() {
    print_header "Cleaning Up Test Artifacts"
    
    # Remove temporary test directories
    find /tmp -name ".aicommit*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    
    # Remove test logs
    find . -name "test-*.log" -mtime +1 -delete 2>/dev/null || true
    
    print_success "Test artifacts cleaned up"
}

show_usage() {
    echo "Usage: $0 [OPTIONS] [CATEGORY]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -c, --clean    Clean up test artifacts only"
    echo "  -s, --security  Run security scan only"
    echo ""
    echo "Categories:"
    for category in "${TEST_CATEGORIES[@]}"; do
        echo "  $category"
    done
    echo ""
    echo "Examples:"
    echo "  $0                    # Run all tests"
    echo "  $0 unit               # Run only unit tests"
    echo "  $0 security            # Run only security tests"
    echo "  $0 --clean            # Clean up test artifacts"
}

main() {
    case "${1:-}" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -c|--clean)
            cleanup_test_artifacts
            exit 0
            ;;
        -s|--security)
            check_dependencies
            run_security_scan
            exit 0
            ;;
        "")
            check_dependencies
            run_security_scan

            # Run all test categories
            for category in "${TEST_CATEGORIES[@]}"; do
                run_test_category "$category"
            done

            if generate_report; then
                cleanup_test_artifacts
            fi
            ;;
        *)
            if [[ " ${TEST_CATEGORIES[*]} " =~ " $1 " ]]; then
                check_dependencies
                run_test_category "$1"
                if generate_report; then
                    cleanup_test_artifacts
                fi
            else
                print_error "Unknown category: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
}

# Run main function with all arguments
main "$@"

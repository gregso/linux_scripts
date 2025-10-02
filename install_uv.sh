#!/bin/bash
# filepath: /home/gsowa/sites/python-manager.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_NAME="Python Version Manager (uv)"
UV_INSTALL_URL="https://astral.sh/uv/install.sh"

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if uv is installed
check_uv_installed() {
    if ! command -v uv &> /dev/null; then
        return 1
    fi
    return 0
}

# Function to install uv
install_uv() {
    print_info "Installing uv..."
    curl -LsSf "$UV_INSTALL_URL" | sh
    
    # Add uv to PATH for current session
    export PATH="$HOME/.cargo/bin:$PATH"
    
    # Add to shell profile
    if [[ -f "$HOME/.bashrc" ]]; then
        echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    if [[ -f "$HOME/.zshrc" ]]; then
        echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.zshrc"
    fi
    
    print_success "uv installed successfully!"
    print_warning "Please restart your terminal or run: source ~/.bashrc"
}

# Function to list available Python versions
list_available_versions() {
    print_info "Available Python versions:"
    uv python list --only-downloads
}

# Function to list installed Python versions
list_installed_versions() {
    print_info "Installed Python versions:"
    uv python list
}

# Function to install a Python version
install_python_version() {
    local version=$1
    if [[ -z "$version" ]]; then
        print_error "Please specify a Python version (e.g., 3.11, 3.12.0)"
        return 1
    fi
    
    print_info "Installing Python $version..."
    uv python install "$version"
    print_success "Python $version installed successfully!"
}

# Function to uninstall a Python version
uninstall_python_version() {
    local version=$1
    if [[ -z "$version" ]]; then
        print_error "Please specify a Python version to uninstall"
        return 1
    fi
    
    print_info "Uninstalling Python $version..."
    uv python uninstall "$version"
    print_success "Python $version uninstalled successfully!"
}

# Function to set default Python version
set_default_python() {
    local version=$1
    if [[ -z "$version" ]]; then
        print_error "Please specify a Python version to set as default"
        return 1
    fi
    
    print_info "Setting Python $version as default..."
    uv python pin "$version"
    print_success "Python $version set as default!"
}

# Function to create a new project with specific Python version
create_project() {
    local project_name=$1
    local python_version=$2
    
    if [[ -z "$project_name" ]]; then
        print_error "Please specify a project name"
        return 1
    fi
    
    print_info "Creating new project: $project_name"
    uv init "$project_name"
    cd "$project_name"
    
    if [[ -n "$python_version" ]]; then
        print_info "Setting Python version to $python_version for this project"
        uv python pin "$python_version"
    fi
    
    print_success "Project $project_name created successfully!"
    print_info "To activate the project environment, run: cd $project_name && uv sync"
}

# Function to show current Python version
show_current_version() {
    print_info "Current Python version:"
    uv python find
}

# Function to update uv
update_uv() {
    print_info "Updating uv..."
    uv self update
    print_success "uv updated successfully!"
}

# Function to show help
show_help() {
    echo -e "${BLUE}$SCRIPT_NAME${NC}"
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  install-uv              Install uv package manager"
    echo "  list-available          List available Python versions for download"
    echo "  list-installed          List installed Python versions"
    echo "  install <version>       Install a specific Python version"
    echo "  uninstall <version>     Uninstall a specific Python version"
    echo "  set-default <version>   Set default Python version"
    echo "  current                 Show current Python version"
    echo "  create <name> [version] Create new project with optional Python version"
    echo "  update-uv               Update uv to latest version"
    echo "  help                    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install 3.12"
    echo "  $0 install 3.11.5"
    echo "  $0 set-default 3.12"
    echo "  $0 create myproject 3.11"
    echo "  $0 list-available"
}

# Main script logic
main() {
    case "${1:-help}" in
        "install-uv")
            if check_uv_installed; then
                print_warning "uv is already installed"
                uv --version
            else
                install_uv
            fi
            ;;
        "list-available")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            list_available_versions
            ;;
        "list-installed")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            list_installed_versions
            ;;
        "install")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            install_python_version "$2"
            ;;
        "uninstall")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            uninstall_python_version "$2"
            ;;
        "set-default")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            set_default_python "$2"
            ;;
        "current")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            show_current_version
            ;;
        "create")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            create_project "$2" "$3"
            ;;
        "update-uv")
            if ! check_uv_installed; then
                print_error "uv is not installed. Run: $0 install-uv"
                exit 1
            fi
            update_uv
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Unknown command: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
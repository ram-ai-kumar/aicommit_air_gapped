# Technical Architecture

> System design, component architecture, and technical implementation details for AI Commit. For security architecture details, see [Security Architecture](SECURITY_ARCHITECTURE.md).

## 🏗️ System Overview

This document covers the complete technical architecture, system design, and implementation details for the AI Commit project, including component interactions, data flows, and technical specifications.

## 🏛️ High-Level Architecture

### Directory Structure

```
~/.aicommit/
├── aicommit.sh              # Entry point (sourced by .zshrc)
├── bin/
│   ├── aicommit             # Standalone executable
│   └── aic                  # Quick-commit executable
├── lib/
│   ├── core.sh              # LLM integration + prompt assembly
│   ├── context-analyzer.sh  # Project type + change analysis
│   ├── backends.sh          # AI backend integration
│   ├── semver.sh            # Semantic versioning engine & manifest updaters
│   └── output-formatter.sh  # Display helpers
├── config/
│   └── defaults.sh          # Default configuration
├── templates/
│   ├── prompt.txt           # LLM prompt template
│   └── conventional-commits.md
├── completions/
│   ├── _aicommit            # Zsh completions
│   └── aicommit.bash        # Bash completions
├── install.sh
└── uninstall.sh
```

### Component Map

```
  ┌─────────────────────────────────────────────────────────────┐
  │  WHAT YOU RUN                                               │
  │                                                             │
  │    aicommit ─── review message before committing            │
  │    aic ──────── commit immediately                          │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  WHAT IT DOES                                               │
  │                                                             │
  │    1. Reads your staged git changes                         │
  │    2. Analyzes project type and change patterns             │
  │    3. Builds a prompt with context and rules      ◄──┐      │
  │    4. Asks the local LLM to write the commit message │      │
```

## 🔧 Core Components

### 1. AI Commit Script (`aicommit.sh`)

**Purpose**: Main entry point and orchestration script  
**Language**: Bash shell script  
**Responsibilities**:

- Environment setup and configuration loading
- Git integration and diff analysis
- AI backend communication
- Output formatting and user interaction

**Key Functions**:

```bash
# Main execution flow
main() {
    load_configuration
    validate_environment
    analyze_git_changes
    generate_commit_message
    format_output
}

# Configuration management
load_configuration() {
    source ~/.aicommitrc 2>/dev/null || true
    source config/defaults.sh
}
```

### 2. Library Functions (`lib/`)

#### core.sh

- **Purpose**: Core business logic and commit message generation
- **Functions**:
  - `generate_prompt()` - Build AI prompt with context
  - `process_response()` - Process AI response
  - `validate_message()` - Validate commit message format

#### backends.sh

- **Purpose**: AI backend integration (Ollama)
- **Functions**:
  - `detect_backend()` - Detect available AI backends
  - `call_ollama()` - Local LLM inference
  - `test_model_loadability()` - Verify model can be loaded

#### context-analyzer.sh

- **Purpose**: Git diff analysis and context building
- **Functions**:
  - `analyze_diff()` - Analyze git diff output
  - `detect_project_type()` - Identify project framework
  - `build_context()` - Build AI context
  - `filter_sensitive_data()` - Remove sensitive information

#### semver.sh

- **Purpose**: Semantic versioning evaluation, manifest manipulation, and Git tagging
- **Functions**:
  - `get_current_version()` - Detect current SemVer across 10+ ecosystems (Node, Rust, Python, Dart/Flutter, Ruby/Rails, PHP Composer, .NET, Java Maven/Gradle, Go, `VERSION` file, git tags)
  - `calculate_next_semver()` - Calculate incremented SemVer for `major`, `minor`, `patch` (handles `v` prefix, prereleases, and Flutter/Dart build numbers)
  - `detect_version_files()` - Detect version-bearing files present in repository
  - `update_version_in_file()` - Perform safe portable in-place version string replacement
  - `apply_semver_file_updates()` - Update all matching manifests in working tree and stage them
  - `create_version_tag()` - Create lightweight or annotated Git tag for the release
  - `evaluate_commit_semver()` - Infer bump level from conventional commit message
  - `suggest_semver_bump()` - Extract conventional bump recommendation

#### output-formatter.sh

- **Purpose**: Result formatting and display
- **Functions**:
  - `format_commit_message()` - Format conventional commits
  - `display_preview()` - Show commit message preview
  - `colorize_output()` - Add color formatting
  - `display_semver_plan()` - Format SemVer release plan preview
  - `display_tag_success()` - Format release tag and updated manifest summary

### 3. Configuration Management (`config/`)

#### defaults.sh

- **Purpose**: Default configuration values
- **Settings**:
  - Default AI model preferences
  - Output formatting options
  - Security and privacy settings
  - SemVer settings (`AI_SEMVER_BUMP`, `AI_SEMVER_TAG`, `AI_SEMVER_TAG_PREFIX`, `AI_SEMVER_DEFAULT_BUMP`, `DEFAULT_INITIAL_VERSION`)

#### User Configuration

- **Location**: `~/.aicommitrc`
- **Format**: Key-value pairs
- **Override**: Environment variables take precedence

#### Configuration Hierarchy

1. **Environment Variables** (highest priority)
2. **User Config** (`~/.aicommitrc`)
3. **Default Config** (`config/defaults.sh`)

### 4. Templates (`templates/`)

#### prompt.txt

- **Purpose**: AI model prompt template
- **Variables**:
  - `{{CONTEXT}}` - Git diff context
  - `{{PROJECT_TYPE}}` - Project framework
  - `{{CHANGE_TYPE}}` - Type of changes
  - `{{RULES}}` - Commit message rules

#### Custom Templates

- User-defined prompt templates
- Project-specific templates
- Language-specific templates

## 🔄 Data Flow Architecture

### Processing Pipeline

```
Git Repository → Diff Analysis → Context Building → AI Backend → Message Generation → Output Formatting
```

### Detailed Flow

1. **Git Integration**
   - Analyze staged changes and generate diff
   - Extract file types and change patterns
   - Identify project framework and conventions

2. **Context Analysis**
   - Build context from file types, changes, and history
   - Filter sensitive data and credentials
   - Create project-specific context

3. **AI Communication**
   - Send context to AI backend for message generation
   - Manage error handling and retries

4. **Result Processing**
   - Format and display generated commit message
   - Validate conventional commit format
   - Provide user preview and confirmation

### Data Structures

#### Git Diff Processing

```bash
# Diff analysis output structure
declare -A diff_analysis
diff_analysis[files]="file1.js file2.py"
diff_analysis[additions]="150"
diff_analysis[deletions]="45"
diff_analysis[file_types]="js py"
diff_analysis[project_type]="javascript"
```

#### AI Context Building

```bash
# Context structure for AI prompt
declare -A ai_context
ai_context[project_name]="my-project"
ai_context[framework]="react"
ai_context[changes]="feature: user authentication"
ai_context[files_modified]="auth.js auth.test.js"
ai_context[sensitive_files]=".env config.json"
```

### SemVer Lifecycle & Tagging Pipeline

When `--bump`, `--semver`, or `AI_SEMVER_BUMP=true` is enabled:

```
Commit Staged Changes
         │
         ▼
Evaluate Commit Message (major / minor / patch / override)
         │
         ▼
Detect Version Files across 10+ Language Manifests
         │
         ▼
Calculate Next SemVer & Preview Release Plan
         │
         ▼
User Confirms Commit (or --yes auto-accepts)
         │
         ▼
Apply Version Updates in Manifest Files & Stage Files
         │
         ▼
Execute Commit (atomic subset in split mode or full tree in single mode)
         │
         ▼
Create Annotated Git Tag (`v${VERSION}`)
         │
         ▼
Display Tag & Updated File Summary
```

#### Multi-Language Manifest Support Matrix

| Ecosystem / Language  | Manifest / Version File                         | Version Pattern / Quirks                                      |
| :-------------------- | :---------------------------------------------- | :------------------------------------------------------------ |
| **Node.js / JS / TS** | `package.json`, `package-lock.json`             | `"version": "x.y.z"`                                          |
| **Rust**              | `Cargo.toml`                                    | `version = "x.y.z"` (package section)                         |
| **Python**            | `pyproject.toml`                                | `version = "x.y.z"` (project or poetry section)               |
| **Dart / Flutter**    | `pubspec.yaml`                                  | `version: x.y.z+build` (preserves & increments build numbers) |
| **Ruby / Rails**      | `*.gemspec`, `lib/**/version.rb`                | `spec.version = "x.y.z"`, `VERSION = "x.y.z"`                 |
| **PHP (Composer)**    | `composer.json`                                 | `"version": "x.y.z"`                                          |
| **.NET (C# / F#)**    | `*.csproj`, `*.fsproj`, `Directory.Build.props` | `<Version>x.y.z</Version>`, `<PackageVersion>`                |
| **Java / JVM**        | `pom.xml`, `build.gradle`, `build.gradle.kts`   | `<version>x.y.z</version>`, `version = 'x.y.z'`               |
| **Go**                | `version.go` / pure Git tags (`vX.Y.Z`)         | Minimal Version Selection (MVS) convention                    |
| **Generic**           | `VERSION`                                       | Plaintext SemVer                                              |

#### Atomic Split Mode (`--split --bump`)

When splitting staged changes into multiple atomic scope commits, SemVer is evaluated and a Git tag is created **for each individual atomic commit**:
1. Current version is read before each scope commit.
2. The scope's specific commit message determines that commit's bump (`feat` -> minor, `fix` -> patch, etc.).
3. Version manifests are updated and included in the atomic subset commit.
4. An annotated tag (e.g. `v1.1.0`, `v1.1.1`) is created pointing directly to that atomic commit.

## 🤖 Backend Architecture

### Supported AI Backends

#### Ollama (Primary)

- **Type**: Local LLM inference
- **Models**: Configured default model (see `config/defaults.sh` for current default)
- **Communication**: HTTP API on localhost:11434

### Backend Selection Logic

```bash
select_backend() {
    local preferred_model="$1"

    # 1. Check configured backend preference (Ollama only)
    if [[ "${AI_BACKEND:-ollama}" == "ollama" ]]; then
        if pgrep -f "ollama" > /dev/null; then
            echo "ollama"
            return 0
        fi
    fi

    # 2. No backend available
    return 1
}
```

### Model Management

#### Model Detection

- Automatic detection of available models
- Model capability assessment
- Size and performance optimization

#### Model Selection

- User preference configuration (`~/.aicommitrc` or `AI_MODEL` env var)
- Single configured model only — no switching to other models or cloud backends
- Performance-based optimization

#### Model Validation

- Model availability checking
- Load testing and validation
- Error handling and recovery

## 🛠️ Technical Implementation

### Error Handling Strategy

#### Graceful Degradation

- **Backend Failures**: Clear error messages (no backend switching)
- **Network Issues**: Local processing when possible
- **Invalid Input**: Helpful error messages and suggestions
- **Resource Limits**: Configurable timeouts and limits

#### Recovery Mechanisms

- **Automatic Retry**: Configurable retry logic for transient failures
- **State Recovery**: Resume interrupted operations
- **Cleanup Procedures**: Ensure system cleanup on errors
- **Error Reporting**: User-friendly error messages

### Performance Considerations

#### Optimization Strategies

- **Caching**: Cache AI responses for similar changes
- **Parallel Processing**: Parallel file analysis when possible
- **Resource Management**: Efficient memory and CPU usage
- **Batch Processing**: Process multiple files together

#### Scalability Design

- **Modular Architecture**: Easy to extend with new features
- **Configuration Flexibility**: Adaptable to different environments
- **Backend Abstraction**: Support for multiple AI providers
- **Plugin System**: Extensible plugin architecture

### Monitoring and Observability

#### Logging Strategy

- **Structured Logging**: Consistent log format for analysis
- **Security Events**: Log security-relevant events
- **Performance Metrics**: Track response times and success rates
- **Debug Information**: Detailed debugging capabilities

#### Debugging Support

- **Verbose Mode**: Detailed debugging information
- **Dry Run**: Preview changes without committing
- **Configuration Validation**: Verify setup before processing
- **Health Checks**: System health monitoring

## 🚀 Deployment Architecture

### Installation Methods

#### System Installation

- **Global Install**: System-wide availability
- **Path Integration**: Automatic PATH configuration
- **Shell Integration**: Zsh/Bash completion setup

#### User Installation

- **Per-User**: Individual user installation
- **Home Directory**: Installation in user home
- **No Sudo Required**: User-level permissions only

#### Portable Operation

- **Standalone**: Operation without installation
- **Self-Contained**: All dependencies included
- **Cross-Platform**: Linux, macOS, Windows support

### Configuration Management

#### Environment Variables

- **AI_MODEL**: Preferred AI model
- **AI_BACKEND**: AI backend selection
- **AICOMMIT_DEBUG**: Enable debug mode
- **AICOMMIT_CONFIG**: Custom config file path

#### Configuration Files

- **~/.aicommitrc**: User configuration
- **config/defaults.sh**: Default settings
- **Project Config**: Project-specific settings

#### Command Line Options

- **--model**: Override AI model
- **--backend**: Override AI backend
- **--dry-run**: Preview without committing
- **--verbose**: Enable verbose output

## 🔌 Integration Points

### Git Integration

#### Git Hooks

- **Pre-commit**: Automatic commit message generation
- **Prepare-commit-msg**: Message validation
- **Post-commit**: Cleanup and logging

#### Workflow Integration

- **CI/CD Pipeline**: Automated commit generation
- **Build System**: Integration with build tools
- **IDE Integration**: Editor plugin support

#### Version Control

- **Git Compatibility**: Full Git workflow support
- **Branch Support**: Multi-branch development
- **Merge Handling**: Merge commit message generation

### AI Backend Integration

#### Local Backends

- **Ollama**: Native local LLM support

#### Cloud Backends

- Not supported in air-gapped mode

#### Backend Abstraction

- **Standard Interface**: Consistent API across backends
- **Configuration**: Backend-specific configuration
- **Single Model**: Single model only (no backend switching)

## 📊 Architecture Evolution

### Current State (v1.x)

- **Architecture**: Monolithic shell script with modular libraries
- **Language**: Bash shell script
- **Deployment**: Single binary with configuration files
- **Dependencies**: Minimal external dependencies

### Future Roadmap

#### v2.0 - Modular Rewrite

- **Language**: Go or Rust rewrite
- **Architecture**: Component-based microservices
- **API**: RESTful API interface
- **Plugin System**: Extensible plugin architecture

#### v2.5 - Enhanced Features

- **Web Interface**: Browser-based management
- **Team Features**: Multi-user support
- **Analytics**: Usage analytics and insights
- **Enterprise**: SSO and enterprise features

#### v3.0 - Cloud Native

- **Container Support**: Docker/Kubernetes deployment
- **Microservices**: Distributed architecture
- **API Gateway**: Centralized API management
- **Monitoring**: Advanced observability

### Technical Debt

#### Current Limitations

- **Shell Script Limitations**: Error handling, performance
- **Single-threaded**: No parallel processing
- **Limited Testing**: Manual testing process
- **Configuration**: Basic configuration management

#### Improvement Areas

- **Error Handling**: Improve error recovery mechanisms
- **Performance**: Optimize for large repositories
- **Testing**: Expand automated test coverage
- **Documentation**: Improve technical documentation

## 🔧 Development Guidelines

### Code Standards

#### Shell Script Best Practices

- **Error Handling**: Comprehensive error checking
- **Variable Handling**: Proper variable quoting
- **Function Organization**: Modular function design
- **Documentation**: Inline code documentation

#### Security Considerations

- **Input Validation**: Validate all user inputs
- **Path Security**: Secure file path handling
- **Permission Management**: Proper permission settings
- **Data Protection**: Sensitive data handling

#### Performance Optimization

- **Efficient Algorithms**: Optimize for performance
- **Resource Management**: Memory and CPU optimization
- **Caching**: Implement appropriate caching
- **Parallel Processing**: Use parallelization where possible

### Testing Strategy

The project uses a single BATS (Bash Automated Testing System) suite under `test/`:

- **Smoke**: Script loading, defaults, help, temp directories
- **Unit**: Individual shell function behavior in `lib/`
- **Negative**: Missing Ollama, missing models, invalid backends
- **Edge**: Empty input, binary files, long diffs, spaces in filenames
- **Security**: Sensitive file exclusion, model-name injection, no model ID exposure
- **Exception**: Ollama errors, memory errors, backend failures
- **Compliance**: Conventional Commit type/scope/length validation
- **Integration**: `--dry-run`, `--verbose`, multi-file staging, end-to-end commits

Run the suite with:

```bash
./test/run_tests.sh        # all categories
bats test/contexts/smoke.bats   # single category
bats test/unit/                 # all unit tests
```

Security scanning is performed with `gitleaks` and `trivy` from `test/run_tests.sh`.

---

## 📞 Technical Resources

### Development Documentation

- [Security Architecture](SECURITY_ARCHITECTURE.md) - Security design and implementation
- [Compliance Framework](COMPLIANCE_FRAMEWORK.md) - Compliance requirements and validation
- [Risk Governance](RISK_GOVERNANCE.md) - Risk management and mitigation
- [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md) - Development roadmap and planning

### Development Resources

- **Source Code**: Main project repository
- **Issue Tracking**: Bug reports and feature requests
- **Development Wiki**: Development guidelines and best practices
- **API Documentation**: Technical API reference

### Support Resources

- **Technical Support**: tech-support@organization.com
- **Development Questions**: dev-questions@organization.com
- **Bug Reports**: bug-reports@organization.com
- **Feature Requests**: feature-requests@organization.com

---

**Document Version**: 1.0  
**Technical Classification**: Internal Technical Documentation  
**Last Updated**: 2026-03-23  
**Next Review**: 2026-04-23  
**Technical Owner**: CTO  
**Implementation Team**: Engineering

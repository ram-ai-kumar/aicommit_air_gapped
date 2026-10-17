# Documentation

Complete documentation for the AI Commit (`aicommit`) project, organized for CXO/CISO stakeholders and technical teams.

## 📚 Documentation Index

### Executive & Strategic Documentation

- **[Executive Overview](docs/EXECUTIVE_OVERVIEW.md)** - Business value proposition, ROI analysis, and strategic alignment for CEO, Board, and executive leadership
- **[Implementation Roadmap](docs/IMPLEMENTATION_ROADMAP.md)** - Strategic implementation plan, development priorities, and feature roadmap with business impact analysis

### Security & Governance Documentation

- **[Security Architecture](docs/SECURITY_ARCHITECTURE.md)** - Comprehensive security design, Zero Trust Architecture implementation, and threat mitigation strategies for CISO and security teams
- **[Compliance Framework](docs/COMPLIANCE_FRAMEWORK.md)** - Regulatory compliance framework, automated validation, and audit readiness for compliance officers and auditors
- **[Risk Governance](docs/RISK_GOVERNANCE.md)** - Enterprise risk management, governance framework, and mitigation strategies for risk officers and board oversight

### Technical Documentation

- **[Technical Architecture](docs/TECHNICAL_ARCHITECTURE.md)** - System design, component architecture, and technical implementation details for CTO and engineering teams

### Quick Reference

- **[Installation Guide](README.md#installation)** - Setup and installation instructions
- **[Configuration](README.md#configuration)** - Environment variables and customization
- **[Usage Examples](README.md#usage)** - Common usage patterns and examples
- **[Testing](README.md#testing)** - Running the BATS test suite

## 🎯 Getting Started

### For Executive Leadership

1. **Strategic Overview**: Start with [Executive Overview](docs/EXECUTIVE_OVERVIEW.md) for business value and ROI analysis
2. **Implementation Planning**: Review [Implementation Roadmap](docs/IMPLEMENTATION_ROADMAP.md) for strategic planning and resource allocation
3. **Risk Assessment**: See [Risk Governance](docs/RISK_GOVERNANCE.md) for enterprise risk management and mitigation

### For Security & Compliance Teams

1. **Security Architecture**: Review [Security Architecture](docs/SECURITY_ARCHITECTURE.md) for Zero Trust implementation and security controls
2. **Compliance Management**: Use [Compliance Framework](docs/COMPLIANCE_FRAMEWORK.md) for regulatory compliance and audit readiness
3. **Risk Management**: Implement [Risk Governance](docs/RISK_GOVERNANCE.md) for enterprise risk assessment and mitigation

### For Technical Teams

1. **System Architecture**: Reference [Technical Architecture](docs/TECHNICAL_ARCHITECTURE.md) for system design and implementation
2. **Security Integration**: Coordinate with [Security Architecture](docs/SECURITY_ARCHITECTURE.md) for secure development practices
3. **Compliance Implementation**: Follow [Compliance Framework](docs/COMPLIANCE_FRAMEWORK.md) for compliant development

### For All Stakeholders

1. **New to aicommit?** Start with the main project README for installation and basic usage
2. **Planning features?** Review [Implementation Roadmap](docs/IMPLEMENTATION_ROADMAP.md) for development priorities and timelines
3. **Security concerns?** See [Security Architecture](docs/SECURITY_ARCHITECTURE.md) for security design and controls
4. **Compliance requirements?** Reference [Compliance Framework](docs/COMPLIANCE_FRAMEWORK.md) for regulatory compliance

## 📖 Documentation Structure

The documentation is organized into stakeholder-focused categories:

### Executive Perspective

- **Business Value**: ROI analysis, competitive advantages, and strategic alignment
- **Investment Justification**: Cost-benefit analysis and resource planning
- **Organizational Impact**: Cultural transformation and competitive positioning

### Security & Governance Perspective

- **Zero Trust Architecture**: Comprehensive security framework implementation
- **Regulatory Compliance**: Multi-framework compliance automation and validation
- **Risk Management**: Enterprise risk assessment and mitigation strategies

### Technical Perspective

- **System Design**: Component architecture and data flow documentation
- **Implementation Details**: Technical specifications and development guidelines
- **Integration Patterns**: Backend integration and deployment architecture

This structure provides role-appropriate documentation while maintaining comprehensive coverage of all project aspects.

## 🚀 Commands & CLI Quick Reference

The toolkit provides 12 executable command-line wrappers in `bin/` and corresponding shell functions:

### Conventional Commits (`aicommit`)
| Command | Mode | Description |
| :--- | :--- | :--- |
| `aicommit` | Interactive | Analyze staged changes and generate commit message interactively |
| `aic` | Non-interactive | Fast all-in-one commit without SemVer |
| `aicc` | Non-interactive | Fast atomic split commits by scope |
| `aics` | Non-interactive | Fast all-in-one commit with SemVer bump & Git tag |
| `aiccs` | Non-interactive | Fast atomic split commits with SemVer bump & Git tag |
| `aicx` | Dry-run | Preview prompt and staged files (0 changes made) |
| `aiccx` | Dry-run | Preview atomic split scope groups (0 changes made) |
| `aicsx` | Dry-run | Preview single commit with SemVer plan (0 changes made) |
| `aiccsx` | Dry-run | Preview atomic split commits with SemVer plan (0 changes made) |

### Standalone Semantic Versioning (`ais` / `aisemver`)
Evaluates and bumps version declarations across manifests and updates `CHANGELOG.md` without making AI commits of code changes:

| Command | Mode | Description |
| :--- | :--- | :--- |
| `ais` | Interactive | Evaluate and bump SemVer interactively across manifests |
| `aisemver` | Alias | Full synonym for `ais` |
| `aisx` | Dry-run | Fast dry-run preview of manifest changes and changelog notes (0 changes made) |

```bash
# Common ais usage patterns:
ais patch                       # Bump patch version across all manifests & update changelog
ais minor -m "New features"     # Bump minor version with custom release note
ais major --no-tag              # Bump major without creating a Git tag
ais 2.5.0                       # Explicitly set version to 2.5.0 across all manifests
ais auto -y                     # Non-interactive auto-bump based on conventional commits
aisx                            # Preview release plan and changelog without modifying files
```

Supported manifest formats (monorepos & polyglot workspaces):
- **Node / JS**: `package.json`, `package-lock.json`
- **Deno / JSR**: `deno.json`, `deno.jsonc`, `jsr.json`
- **Python**: `pyproject.toml`, `setup.py`, `setup.cfg`, `*version*.py`
- **Rust**: `Cargo.toml`
- **Go**: `*version*.go`
- **Dart / Flutter**: `pubspec.yaml`
- **Ruby**: `*.gemspec`, `version.rb`
- **PHP**: `composer.json`
- **Java / Kotlin / Gradle**: `pom.xml`, `build.gradle`, `build.gradle.kts`, `gradle.properties`
- **.NET**: `*.csproj`, `*.fsproj`, `Directory.Build.props`
- **Swift**: `Package.swift`, `project.pbxproj`
- **Elixir**: `mix.exs`
- **CMake**: `CMakeLists.txt`
- **Helm**: `Chart.yaml`
- **Generic**: `VERSION`, `.version`

## 🧪 Testing

The project uses BATS (Bash Automated Testing System) as its single test framework:

```bash
./test/run_tests.sh              # run all 8 categories
bats test/contexts/smoke.bats    # run smoke tests only
bats test/unit/                  # run unit tests
./test/run_tests.sh --security   # run the security scan
```

Test categories: smoke, unit, negative, edge, security, exception, compliance, integration.

## 🔗 Cross-References

### Documentation Dependencies

- **Security → Technical**: Security architecture references technical implementation details
- **Compliance → Security**: Compliance framework leverages security controls
- **Risk → Security**: Risk governance depends on security architecture
- **Executive → All**: Executive overview synthesizes all perspectives

### Integration Points

- **Implementation Planning**: Executive overview aligns with implementation roadmap
- **Security Implementation**: Security architecture guides technical implementation
- **Compliance Validation**: Compliance framework validates security controls
- **Risk Mitigation**: Risk governance addresses security and compliance risks

---

## 📞 Documentation Support

### Documentation Contacts

- **Documentation Lead**: docs@organization.com
- **Security Questions**: security-docs@organization.com
- **Compliance Support**: compliance-docs@organization.com
- **Technical Issues**: tech-docs@organization.com

### Contribution Guidelines

- **Executive Content**: Direct business and strategic content to executive team
- **Security Content**: Route security documentation to security team
- **Technical Content**: Submit technical documentation to engineering team
- **Compliance Content**: Forward compliance questions to compliance team

---

**Documentation Version**: 3.0
**Last Updated**: 2026-09-03
**Documentation Owner**: Documentation Team
**Stakeholder Coverage**: Executive, Security, Compliance, Technical

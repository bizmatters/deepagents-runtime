"""
Post-Work Validation Tool - Checks if specialist agents created their mandatory deliverables.

This tool performs Quality Control (QC) checks after each specialist completes,
verifying that all mandatory deliverable files exist and contain required content.
"""
from typing import Dict, List, Annotated, TypedDict, Protocol, Tuple
from langchain_core.tools import tool
from langchain.tools import InjectedState
from abc import ABC, abstractmethod
from dataclasses import dataclass
import re
import json
import jsonschema
from pathlib import Path


class FileData(TypedDict):
    """Data structure for storing file contents with metadata."""
    content: List[str]
    created_at: str
    modified_at: str


# ============================================================================
# Validator Classes - Each handles one type of validation
# ============================================================================

@dataclass
class ValidationResult:
    """Result of a validation check."""
    passed: bool
    errors: List[str]
    
    @classmethod
    def success(cls) -> "ValidationResult":
        return cls(passed=True, errors=[])
    
    @classmethod
    def failure(cls, errors: List[str]) -> "ValidationResult":
        return cls(passed=False, errors=errors)
    
    def merge(self, other: "ValidationResult") -> "ValidationResult":
        """Merge two validation results."""
        return ValidationResult(
            passed=self.passed and other.passed,
            errors=self.errors + other.errors
        )


class ContentValidator(ABC):
    """Base class for content validators."""
    
    @abstractmethod
    def validate(self, content: str, file_path: str) -> ValidationResult:
        """Validate content and return result."""
        pass


class StringValidator(ContentValidator):
    """Validates that a string exists in content with lenient matching."""
    
    def __init__(self, required_string: str):
        self.required_string = required_string
    
    def _normalize_for_matching(self, text: str) -> str:
        """
        Normalize text for lenient matching:
        - Lowercase
        - Remove all special characters and spaces
        - Keep only alphanumeric characters
        
        This allows matching:
        - "Overall Assessment" = "OverallAssessment" = "Overall+Assessment" = "Overall_Assessment"
        """
        return re.sub(r'[^a-z0-9]', '', text.lower())
    
    def validate(self, content: str, file_path: str) -> ValidationResult:
        """
        Lenient validation that accepts variations in spacing and special characters.
        Examples that will match "## Overall Assessment":
        - "## Overall Assessment"
        - "## Overall+Assessment"
        - "## Overall_Assessment"
        - "## OverallAssessment"
        - "##Overall Assessment"
        - Case variations: "overall assessment", "OVERALL ASSESSMENT"
        """
        # Normalize both strings - remove special chars and spaces, lowercase
        normalized_content = self._normalize_for_matching(content)
        normalized_required = self._normalize_for_matching(self.required_string)
        
        # Check if the normalized required string is in the normalized content
        if normalized_required in normalized_content:
            return ValidationResult.success()
        
        return ValidationResult.failure([
            f"{file_path}: Missing required content '{self.required_string}'"
        ])


class SectionValidator(ContentValidator):
    """Validates that a section header exists in content with lenient matching."""
    
    def __init__(self, section_title: str):
        self.section_title = section_title
    
    def _normalize_for_matching(self, text: str) -> str:
        """
        Normalize text for lenient matching:
        - Lowercase
        - Remove all special characters and spaces
        - Keep only alphanumeric characters
        """
        return re.sub(r'[^a-z0-9]', '', text.lower())
    
    def validate(self, content: str, file_path: str) -> ValidationResult:
        """
        Lenient section validation that accepts variations in spacing and special characters.
        Examples that will match "## Overall Assessment":
        - "## Overall Assessment"
        - "## Overall+Assessment"
        - "## Overall_Assessment"
        - "## OverallAssessment"
        - Case variations: "overall assessment", "OVERALL ASSESSMENT"
        """
        # Normalize both strings - remove special chars and spaces, lowercase
        normalized_content = self._normalize_for_matching(content)
        normalized_section = self._normalize_for_matching(self.section_title)
        
        # Check if the normalized section is in the normalized content
        if normalized_section in normalized_content:
            return ValidationResult.success()
        
        return ValidationResult.failure([
            f"{file_path}: Missing section '{self.section_title}'"
        ])


class FilePatternValidator(ContentValidator):
    """Validates file entries within a section match pattern and contain required mentions."""
    
    def __init__(self, section: str, file_pattern: str, required_mentions: List[str]):
        self.section = section
        self.file_pattern = file_pattern
        self.required_mentions = required_mentions
    
    def validate(self, content: str, file_path: str) -> ValidationResult:
        errors = []
        
        # Find the section
        section_match = re.search(rf'^{re.escape(self.section)}', content, re.MULTILINE | re.IGNORECASE)
        if not section_match:
            mentions_str = ", ".join(self.required_mentions)
            return ValidationResult.failure([
                f"{file_path}: Section '{self.section}' not found (should mention: {mentions_str})"
            ])
        
        # Extract section content
        section_start = section_match.end()
        next_section = re.search(r'^##\s+[^#]', content[section_start:], re.MULTILINE)
        section_content = content[section_start:section_start + next_section.start()] if next_section else content[section_start:]
        
        # Find file entries
        file_entries = re.finditer(r'###\s+\d+\.\s+\*\*File:\*\*\s+`([^`]+)`', section_content, re.IGNORECASE)
        
        file_found = False
        for match in file_entries:
            matched_path = match.group(1)
            if not re.search(self.file_pattern, matched_path):
                continue
            
            file_found = True
            
            # Get entry content
            entry_start = match.start()
            next_file = re.search(r'###\s+\d+\.\s+\*\*File:\*\*', section_content[match.end():])
            entry_content = section_content[entry_start:match.end() + next_file.start()] if next_file else section_content[entry_start:]
            
            # Check required mentions
            missing = [m for m in self.required_mentions if m not in entry_content]
            if missing:
                errors.append(f"{file_path}: File '{matched_path}': Missing required mentions {missing}")
        
        if not file_found:
            errors.append(f"{file_path}: No files matching pattern '{self.file_pattern}' found in section '{self.section}'")
        
        return ValidationResult.failure(errors) if errors else ValidationResult.success()


class JsonSchemaValidator(ContentValidator):
    """Validates JSON content against a JSON schema."""
    
    # Embedded schema for definition.json - avoids file loading issues in runtime
    DEFINITION_SCHEMA = {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "title": "DeepAgents Multi-Agent Workflow Definition Schema",
        "description": "Schema for validating multi-agent workflow definition.json files",
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "Name of the workflow definition"},
            "version": {"type": "string", "description": "Version of the workflow definition"},
            "tool_definitions": {
                "type": "array",
                "description": "Array of tool definitions available to agents",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Name of the tool"},
                        "runtime": {
                            "type": "object",
                            "properties": {
                                "script": {"type": "string", "description": "Python script implementing the tool"},
                                "dependencies": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": "List of Python package dependencies"
                                }
                            },
                            "required": ["script", "dependencies"]
                        }
                    },
                    "required": ["name", "runtime"]
                }
            },
            "nodes": {
                "type": "array",
                "description": "Array of agent nodes in the workflow",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string", "description": "Unique identifier for the node"},
                        "type": {"type": "string", "enum": ["Orchestrator", "Specialist"], "description": "Type of the agent node"},
                        "config": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string", "description": "Display name of the agent"},
                                "description": {"type": "string", "description": "Description of the agent's purpose"},
                                "system_prompt": {"type": "string", "description": "System prompt for the agent"},
                                "model": {
                                    "type": "object",
                                    "properties": {
                                        "provider": {"type": "string", "enum": ["openai", "anthropic", "ollama"], "description": "LLM provider"},
                                        "model": {"type": "string", "description": "Model identifier"}
                                    },
                                    "required": ["provider", "model"]
                                },
                                "tools": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": "List of tool names available to this agent"
                                },
                                "state_schema": {"type": "object", "description": "Optional state schema for agents with state management"}
                            },
                            "required": ["name", "system_prompt", "model", "tools"]
                        }
                    },
                    "required": ["id", "type", "config"]
                }
            },
            "edges": {
                "type": "array",
                "description": "Array of edges defining workflow connections",
                "items": {
                    "type": "object",
                    "properties": {
                        "source": {"type": "string", "description": "Source node ID"},
                        "target": {"type": "string", "description": "Target node ID"},
                        "type": {"type": "string", "enum": ["orchestrator", "specialists"], "description": "Type of edge connection"}
                    },
                    "required": ["source", "target", "type"]
                }
            }
        },
        "required": ["name", "version", "tool_definitions", "nodes", "edges"]
    }
    
    def __init__(self, schema_path: str):
        self.schema_path = schema_path
        self._schema = None
    
    def _load_schema(self) -> Dict:
        """Load the JSON schema - uses embedded schema."""
        if self._schema is None:
            # Use embedded schema for definition.json
            if self.schema_path == "schema.json":
                self._schema = self.DEFINITION_SCHEMA
            else:
                raise ValueError(f"Unknown schema: {self.schema_path}. Only 'schema.json' is supported.")
        
        return self._schema
    
    def validate(self, content: str, file_path: str) -> ValidationResult:
        """Validate JSON content against the schema."""
        try:
            # Parse JSON content
            try:
                json_data = json.loads(content)
            except json.JSONDecodeError as e:
                return ValidationResult.failure([
                    f"{file_path}: Invalid JSON format - {str(e)}"
                ])
            
            # Load and validate against schema
            try:
                schema = self._load_schema()
                jsonschema.validate(instance=json_data, schema=schema)
                return ValidationResult.success()
            
            except jsonschema.ValidationError as e:
                # Format the validation error nicely
                error_path = " -> ".join(str(p) for p in e.absolute_path) if e.absolute_path else "root"
                return ValidationResult.failure([
                    f"{file_path}: Schema validation failed at '{error_path}' - {e.message}"
                ])
            
            except jsonschema.SchemaError as e:
                return ValidationResult.failure([
                    f"{file_path}: Invalid schema file - {str(e)}"
                ])
            
            except FileNotFoundError as e:
                return ValidationResult.failure([
                    f"{file_path}: Schema validation failed - {str(e)}"
                ])
        
        except Exception as e:
            return ValidationResult.failure([
                f"{file_path}: Unexpected error during JSON schema validation - {str(e)}"
            ])


# ============================================================================
# Validator Factory - Creates validators from config
# ============================================================================

def create_validators(config_item, file_path: str = "") -> List[ContentValidator]:
    """Create validators from a config item, with automatic JSON schema detection."""
    if isinstance(config_item, str):
        return [StringValidator(config_item)]
    
    if isinstance(config_item, dict):
        section = config_item.get("section", "")
        
        if "schema_path" in config_item:
            return [JsonSchemaValidator(config_item["schema_path"])]
        elif "file_pattern" in config_item and "required_mentions" in config_item:
            return [FilePatternValidator(
                section=section,
                file_pattern=config_item["file_pattern"],
                required_mentions=config_item["required_mentions"]
            )]
        elif section:
            return [SectionValidator(section)]
    
    # Auto-detect JSON files and apply schema validation
    if file_path.endswith('.json'):
        # For JSON files, try to find a corresponding schema file
        if file_path == "/definition.json":
            return [JsonSchemaValidator("schema.json")]
        # Add more JSON file mappings as needed
        # elif file_path == "/other.json":
        #     return [JsonSchemaValidator("other_schema.json")]
    
    return []


# ============================================================================
# Main Validation Logic
# ============================================================================

class AgentValidator:
    """Validates deliverables for a specific agent."""
    
    def __init__(self, agent_name: str, config: Dict):
        self.agent_name = agent_name
        self.description = config["description"]
        self.content_checks = config.get("content_checks", {})
        self.directory_checks = config.get("directory_checks", {})
    
    @property
    def required_paths(self) -> List[str]:
        return list(self.content_checks.keys()) + list(self.directory_checks.keys())
    
    def validate(self, files: Dict[str, FileData]) -> Tuple[List[str], List[str], List[str]]:
        """
        Validate all deliverables.
        Returns: (missing_files, content_errors, directory_errors)
        """
        missing_files = self._check_file_existence(files)
        
        # Only check content if files exist
        content_errors = [] if missing_files else self._check_content(files)
        directory_errors = self._check_directories(files)
        
        return missing_files, content_errors, directory_errors
    
    def _check_file_existence(self, files: Dict[str, FileData]) -> List[str]:
        """Check if required files exist."""
        missing = []
        for path in self.required_paths:
            if path.endswith("/"):
                # Directory check
                if not any(f.startswith(path) for f in files.keys()):
                    missing.append(f"{path} (directory does not exist or is empty)")
            elif path not in files:
                missing.append(path)
        return missing
    
    def _check_content(self, files: Dict[str, FileData]) -> List[str]:
        """Validate file content."""
        errors = []
        for file_path, checks in self.content_checks.items():
            if file_path not in files:
                continue
            
            content = "\n".join(files[file_path]["content"])
            
            # If no explicit checks are provided for JSON files, auto-apply schema validation
            if not checks and file_path.endswith('.json'):
                validators = create_validators({}, file_path)
                for validator in validators:
                    result = validator.validate(content, file_path)
                    errors.extend(result.errors)
            else:
                # Apply explicit checks
                for check in checks:
                    for validator in create_validators(check, file_path):
                        result = validator.validate(content, file_path)
                        errors.extend(result.errors)
        
        return errors
    
    def _check_directories(self, files: Dict[str, FileData]) -> List[str]:
        """Validate directory contents."""
        errors = []
        
        for dir_path, config in self.directory_checks.items():
            dir_files = {f: files[f] for f in files if f.startswith(dir_path)}
            
            if not dir_files:
                errors.append(f"{dir_path}: Directory does not exist or is empty")
                continue
            
            file_pattern = config.get("file_pattern", "")
            required_sections = config.get("required_sections", [])
            
            if not file_pattern:
                continue
            
            # Filter by pattern
            pattern_files = {
                f: d for f, d in dir_files.items()
                if re.search(file_pattern, f.replace(dir_path, ""))
            }
            
            if not pattern_files:
                errors.append(f"{dir_path}: No files matching pattern '{file_pattern}' found")
                continue
            
            # Check sections in each file
            for file_path, file_data in pattern_files.items():
                content = "\n".join(file_data["content"])
                for section in required_sections:
                    validator = StringValidator(section)
                    result = validator.validate(content, file_path)
                    # Reformat error message for directory context
                    for err in result.errors:
                        errors.append(err.replace("Missing required content", "Missing required section"))
        
        return errors


# ============================================================================
# Error Message Builder
# ============================================================================

class ErrorMessageBuilder:
    """Builds formatted error messages."""
    
    ERROR_TYPES = {
        "missing files": ("create the missing files", "Create the following missing files"),
        "content issues": ("fix the content issues", "Fix the following content issues"),
        "directory issues": ("fix the directory issues", "Fix the following directory issues"),
    }
    
    def __init__(self, agent_name: str, description: str):
        self.agent_name = agent_name
        self.description = description
    
    def build(self, missing: List[str], content_errors: List[str], dir_errors: List[str]) -> str:
        """Build the complete error message."""
        error_parts = []
        all_errors = []
        
        if missing:
            error_parts.append(self._format_list("Missing files", missing))
            all_errors.append(("missing files", missing))
        
        if content_errors:
            error_parts.append(self._format_list("Content validation failures", content_errors))
            all_errors.append(("content issues", content_errors))
        
        if dir_errors:
            error_parts.append(self._format_list("Directory validation failures", dir_errors))
            all_errors.append(("directory issues", dir_errors))
        
        action_msg, example_prompt = self._build_revision_prompt(all_errors)
        
        return f'''✗ QC FAILED: Deliverable validation failed for {self.agent_name}

Expected: {self.description}

{chr(10).join(error_parts)}

REQUIRED ACTION:
Re-invoke the {self.agent_name} with a detailed prompt specifying what needs to be fixed.
The agent must {action_msg} before proceeding to the next step.

Example revision prompt:
"{example_prompt}

Please generate/update these files now according to the implementation plan."'''
    
    def _format_list(self, title: str, items: List[str]) -> str:
        return f"{title}:\n  - " + "\n  - ".join(items)
    
    def _build_revision_prompt(self, all_errors: List[Tuple[str, List[str]]]) -> Tuple[str, str]:
        """Build action message and example prompt."""
        if len(all_errors) == 1:
            error_type, error_list = all_errors[0]
            action, prompt_prefix = self.ERROR_TYPES[error_type]
            prompt = f"The QC check failed. You must {prompt_prefix.lower()}:\n" + \
                     "\n".join(f"   - {e}" for e in error_list)
            return action, prompt
        
        # Multiple error types
        actions = []
        prompts = []
        for i, (error_type, error_list) in enumerate(all_errors, 1):
            action, prompt_prefix = self.ERROR_TYPES[error_type]
            actions.append(action)
            prompts.append(f"{i}. {prompt_prefix}:\n" + "\n".join(f"   - {e}" for e in error_list))
        
        return " AND ".join(actions), "The QC check failed. You must:\n" + "\n".join(prompts)


# ============================================================================
# Agent Configuration
# ============================================================================

AGENT_DELIVERABLES = {
    "Guardrail Agent": {
        "description": "Guardrail assessment document with security and policy validation",
        "content_checks": {
            "/guardrail_assessment.md": [
                {"section": "## Overall Assessment"},
                {"section": "## Contextual Guardrails"},
                "Status:"
            ]
        }
    },
    "Impact Analysis Agent": {
        "description": "Impact assessment with file-by-file implementation plan",
        "content_checks": {
            "/impact_assessment.md": [
                {"section": "## Constitutional Compliance Analysis"},
                {
                    "section": "## File-by-File Implementation Plan",
                    "file_pattern": r"/THE_SPEC/.*\.md",
                    "required_mentions": ["requirements.md", "constitution.md", "plan.md"]
                },
                {
                    "section": "## File-by-File Implementation Plan",
                    "file_pattern": r"/THE_CAST/.*\.md",
                    "required_mentions": ["## Tools", "## System Prompt"]
                }
            ]
        }
    },
    "Workflow Spec Agent": {
        "description": "Workflow-level specification files (constitution, plan, requirements)",
        "content_checks": {
            "/THE_SPEC/constitution.md": [
                {"section": "## 1. Principle"},
                {"section": "## 2. Principle"},
                "governance"
            ],
            "/THE_SPEC/plan.md": [
                {"section": "## Step-by-Step Execution Flow"},
                "OrchestratorAgent"
            ],
            "/THE_SPEC/requirements.md": [
                {"section": "## Input Schema"},
                "input_schema"
            ]
        }
    },
    "Agent Spec Agent": {
        "description": "Agent specification files in /THE_CAST/ directory",
        "directory_checks": {
            "/THE_CAST/": {
                "file_pattern": r".*\.md$",
                "required_sections": ["## System Prompt", "## Tools"]
            }
        }
    },
    "Multi-Agent Compiler Agent": {
        "description": "Compiled workflow definition",
        "content_checks": {
            "/definition.json": [
                {"schema_path": "schema.json"}
            ]
        }
    }
}


# ============================================================================
# Tool Entry Point
# ============================================================================

@tool
def post_work(
    agent_name: str,
    files: Annotated[Dict[str, FileData], InjectedState("files")]
) -> str:
    """Validates that a specialist agent created all mandatory deliverable files.
    
    This tool checks the agent state files to ensure all required files exist after
    a specialist agent completes. Use this for Quality Control (QC) after each
    specialist finishes to catch missing deliverables early.
    
    Args:
        agent_name: Name of the specialist agent to verify (e.g., "Impact Analysis Agent")
        files: Agent state files dict (automatically injected, not visible to LLM)
    
    Returns:
        Success message if all files exist, or detailed error with missing files list.
    """
    # Input validation
    if files is None:
        return "✗ QC ERROR: Files dict is None. This indicates InjectedState is not working correctly."
    
    if not isinstance(files, dict):
        return f"✗ QC ERROR: Files is not a dict, got type: {type(files)}"
    
    if agent_name not in AGENT_DELIVERABLES:
        available = ", ".join(AGENT_DELIVERABLES.keys())
        return f'Error: Unknown agent name "{agent_name}".\n\nAvailable agents for verification:\n{available}\n\nPlease use the exact agent name from the list above.'
    
    # Validate
    config = AGENT_DELIVERABLES[agent_name]
    validator = AgentValidator(agent_name, config)
    
    if not validator.content_checks and not validator.directory_checks:
        return f"✗ QC ERROR: No validation rules defined for {agent_name}."
    
    missing, content_errors, dir_errors = validator.validate(files)
    
    # Return result
    if not missing and not content_errors and not dir_errors:
        return f"✓ QC PASSED: All mandatory deliverables verified for {agent_name}"
    
    builder = ErrorMessageBuilder(agent_name, config["description"])
    return builder.build(missing, content_errors, dir_errors)

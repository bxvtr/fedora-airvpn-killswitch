#!/usr/bin/env bash
# Null-delimited Ansible argv helpers for the live VM orchestrator.
# These helpers construct arguments only; they never execute ansible-playbook
# and never handle passwords.
#
# shellcheck shell=bash

# Args: inventory_path python_interpreter
# Prints null-delimited common controller args.
it_ansible_common_args() {
  local inventory="$1"
  local python_interp="$2"
  printf '%s\0' \
    -i "${inventory}" \
    -e "ansible_python_interpreter=${python_interp}"
}

# Args: inventory_path python_interpreter playbook [extra...]
# Prints null-delimited lifecycle args including --ask-become-pass.
it_ansible_lifecycle_args() {
  local inventory="$1"
  local python_interp="$2"
  local playbook="$3"
  shift 3
  local arg extra
  while IFS= read -r -d '' arg; do
    printf '%s\0' "${arg}"
  done < <(it_ansible_common_args "${inventory}" "${python_interp}")
  printf '%s\0' --ask-become-pass
  printf '%s\0' "${playbook}"
  for extra in "$@"; do
    printf '%s\0' "${extra}"
  done
}

# Read null-delimited args from stdin; return 0 if --ask-become-pass is present.
it_ansible_args_have_ask_become() {
  local arg
  while IFS= read -r -d '' arg; do
    if [[ "${arg}" == "--ask-become-pass" ]]; then
      return 0
    fi
  done
  return 1
}

# Read null-delimited args from stdin; return 0 if --syntax-check is present.
it_ansible_args_have_syntax_check() {
  local arg
  while IFS= read -r -d '' arg; do
    if [[ "${arg}" == "--syntax-check" ]]; then
      return 0
    fi
  done
  return 1
}

enum PermissionMode { requestApproval, policyAuto, fullAccess }

PermissionMode permissionModeFromJson(Object? value) {
  return PermissionMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => PermissionMode.requestApproval,
  );
}

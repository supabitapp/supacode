#if compiler(>=6)
  extension WritableKeyPath: @retroactive @unchecked Sendable {}
#endif

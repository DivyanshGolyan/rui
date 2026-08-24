# Use two tools and final assistant text

OnePage v1 exposes only `bash` and `apply_patch`; permission remains an independent allow, ask, or deny decision for each immutable tool call. A valid tool call executes and returns its Result to the next model turn, while a complete non-empty assistant response with no tool call is the Final Answer. Dedicated search, read, verification, finish, and stop actions would duplicate shell or model-protocol behavior and enlarge the core without adding capability.

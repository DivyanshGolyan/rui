// Generated from openapi.json by scripts/generate-settings.mjs. Do not edit.
export const SETTINGS_KINDS = {
	"fields": {
		"store": {
			"fields": {
				"sqlite": {
					"fields": {
						"dir": {
							"kind": "bytes"
						}
					}
				},
				"mysql": {
					"fields": {
						"url": {
							"kind": "secret",
							"fields": {
								"env": {
									"kind": "bytes"
								},
								"file": {
									"kind": "bytes"
								}
							}
						}
					}
				}
			}
		},
		"providers": {
			"fields": {
				"codex": {
					"fields": {
						"credentialFile": {
							"kind": "bytes"
						}
					}
				},
				"openai": {
					"fields": {
						"key": {
							"kind": "secret",
							"fields": {
								"env": {
									"kind": "bytes"
								},
								"file": {
									"kind": "bytes"
								}
							}
						}
					}
				},
				"chatgpt": {
					"fields": {
						"credentialFile": {
							"kind": "bytes"
						}
					}
				}
			}
		},
		"network": {
			"fields": {
				"caFile": {
					"kind": "bytes"
				}
			}
		},
		"tools": {
			"fields": {
				"bash": {
					"fields": {
						"path": {
							"kind": "bytes"
						}
					}
				},
				"mcp": {
					"fields": {
						"*": {
							"fields": {
								"bearerToken": {
									"kind": "secret",
									"fields": {
										"env": {
											"kind": "bytes"
										},
										"file": {
											"kind": "bytes"
										}
									}
								}
							}
						}
					}
				}
			}
		},
		"interface": {
			"fields": {
				"dir": {
					"kind": "bytes"
				}
			}
		}
	}
} as const;

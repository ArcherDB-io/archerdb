// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 ArcherDB Contributors

/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['**/test_all_operations.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['ts-jest', {
      useESM: false,
      isolatedModules: true,
    }],
  },
  // Increase timeout for integration tests
  testTimeout: 120000,
  // Run tests sequentially
  maxWorkers: 1,
  // Verbose output
  verbose: true,
  // Global setup/teardown for cluster lifecycle
  globalSetup: undefined,
  globalTeardown: undefined,
  // Suppress console output during tests
  silent: false,
};

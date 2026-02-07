// Minimal Jest environment that skips localStorage
const {LegacyFakeTimers, ModernFakeTimers} = require('@jest/fake-timers');
const {JestEnvironment} = require('@jest/environment');

class MinimalEnvironment {
  constructor(config, context) {
    this.global = global;
    this.fakeTimers = null;
    this.fakeTimersModern = null;
    this.context = context;
  }

  async setup() {
    // Minimal setup without DOM/localStorage
  }

  async teardown() {
    // Cleanup
  }

  getVmContext() {
    return null;
  }

  async handleTestEvent(event, state) {
    // Event handling
  }
}

module.exports = MinimalEnvironment;

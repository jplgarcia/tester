import Sequencer from '@jest/test-sequencer';
import path from 'path';

export default class AlphaSequencer extends Sequencer.default {
  sort(tests) {
    // Sort by filename so 00- runs before 01- runs before 02- etc.
    return [...tests].sort((a, b) =>
      path.basename(a.path).localeCompare(path.basename(b.path))
    );
  }
}

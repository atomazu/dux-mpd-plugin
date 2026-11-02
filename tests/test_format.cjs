const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, '../Format.js'), 'utf8'), ctx);

assert.equal(ctx.duration(0), '0:00');
assert.equal(ctx.duration(65.9), '1:05');
assert.equal(ctx.duration(3725), '1:02:05');
assert.equal(ctx.duration(-4), '0:00');
assert.equal(ctx.summary({ ok: false }), 'Unavailable');
assert.equal(ctx.summary({ ok: true, state: 'stop', playlistLength: 0 }), 'Queue empty');
assert.equal(ctx.summary({ ok: true, state: 'stop', playlistLength: 4 }), 'Stopped');
assert.equal(ctx.summary({ ok: true, state: 'play', playbackError: 'Failed to open audio output' }), 'Playback error');
assert.equal(ctx.pillText({ ok: true, state: 'play', song: { title: 'Blue Train', artist: 'John Coltrane' } }, true), 'John Coltrane — Blue Train');
assert.equal(ctx.pillText({ ok: true, state: 'play', song: { title: 'Blue Train', artist: 'John Coltrane' } }, false), 'Blue Train');
assert.equal(ctx.hoverText({ ok: true, state: 'play', song: { title: 'Blue Train', artist: 'John Coltrane', album: 'Blue Train' } }), 'John Coltrane • Blue Train • Blue Train');
assert.equal(ctx.hoverText({ ok: false }), 'MPD unavailable');
assert.equal(ctx.audioFormat('44100:16:2', 320), '44.1 kHz · 16-bit · Stereo · 320 kbps');
assert.equal(ctx.audioFormat('96000:24:2', null), '96 kHz · 24-bit · Stereo');
assert.equal(ctx.singleLabel('oneshot'), 'Single 1×');

console.log('15 status/format checks passed');

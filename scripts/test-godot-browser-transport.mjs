import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const bridge = readFileSync(new URL('../sdk/godot/addons/gamenight/browser_transport.js', import.meta.url), 'utf8');
const origin = 'https://club.example';
const channel = 'splitscreen-club-webgame-v1';

function frame(parent) {
  const window = {};
  const context = {window, parent: parent ?? window, location: {origin}};
  let deliver;
  context.addEventListener = (type, fn) => { if (type === 'message') deliver = fn; };
  vm.runInNewContext(bridge, context);
  return {transport: window.SplitscreenClubWebGame, deliver};
}

assert.equal(frame().transport, undefined);
const otherOrigin = {get location() { throw new Error('Cross-origin frame'); }};
assert.equal(frame(otherOrigin).transport, undefined);

const sent = [];
const parent = {location: {origin}, postMessage: (message, target) => sent.push([message, target])};
const {transport, deliver} = frame(parent);
const received = [];
transport.bindReceiver(json => received.push(JSON.parse(json)));
transport.sendToParent(JSON.stringify({type: 'hello', game: 'test'}));
assert.equal(sent[0][0].channel, channel);
assert.equal(sent[0][1], origin);
assert.equal(sent[0][0].payload.game, 'test');

const event = {source: parent, origin, data: {channel, payload: {type: 'pause', session: 's1'}}};
deliver({...event, source: {}});
deliver({...event, origin: 'https://other.example'});
deliver({...event, data: {...event.data, channel: 'other'}});
assert.deepEqual(received, []);
deliver(event);
assert.deepEqual(received, [event.data.payload]);
console.log('PASS standalone, iframe sender and origin validation, protocol envelope');

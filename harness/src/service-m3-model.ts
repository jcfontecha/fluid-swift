import { EventEmitter } from 'node:events';
import { SummarizerClientElection } from '../node_modules/@fluidframework/container-runtime/lib/summary/summarizerClientElection.js';
import { SummarizeHeuristicData, SummarizeHeuristicRunner } from '../node_modules/@fluidframework/container-runtime/lib/summary/summaryDelayLoadedModule/summarizerHeuristics.js';
import { DefaultSummaryConfiguration } from '../node_modules/@fluidframework/container-runtime/lib/summary/summaryHelpers.js';
import { createChildLogger } from '@fluidframework/telemetry-utils/internal';
import type { ISequencedClient } from '@fluidframework/driver-definitions/internal';
import assert from 'node:assert/strict';

export function modelScenario(seed: number) {
    type Step = { type: string; sequence: number; now: number; member?: [string, ISequencedClient]; id?: string };
    const steps: Step[] = [];
    function add(type: string, extra: Partial<Step> = {}) {
        steps.push({ type, sequence: steps.length + 1, now: steps.length * (seed % 2 === 0 ? 500 : 23), ...extra });
    }
    function join(id: string, summarizer: boolean) {
        add('join', { member: [id, { sequenceNumber: steps.length + 1, client: {
            mode: 'write', details: { capabilities: { interactive: !summarizer }, ...(summarizer ? { type: 'summarizer' } : {}) },
            permission: [], scopes: [], user: { id },
        } }] });
    }
    join('swift', false);
    join('ts', false);
    join('child', true);
    for (let n = 0; n < 105; n++) add(n % 7 === 0 ? 'noop' : 'op');
    add('attempt');
    for (let n = 0; n < 20; n++) add('op');
    add('ack');
    add('leave', { id: 'swift' });
    add('leave', { id: 'child' });
    join('ts-child', true);
    add('leave', { id: 'ts-child' });
    add('leave', { id: 'ts' });
    join('swift-new', false);
    const members = new Map<string, ISequencedClient>();
    const quorum = Object.assign(new EventEmitter(), { getMembers: () => members, getMember: (id: string) => members.get(id) });
    const collection = new EventEmitter();
    const delta = { lastSequenceNumber: 0 };
    const election = new SummarizerClientElection({ send() {} }, delta, quorum, collection, 7000, 0);
    const data = new SummarizeHeuristicData(0, { refSequenceNumber: 0, summaryTime: 0 });
    let reason: string | null = null;
    assert(DefaultSummaryConfiguration.state === 'enabled');
    const runner = new SummarizeHeuristicRunner(data, DefaultSummaryConfiguration, value => { reason = value; }, createChildLogger({ logger: { send() {} } }));
    const original = Date.now;
    try {
        const expected = steps.map(step => {
            Date.now = () => step.now;
            delta.lastSequenceNumber = step.sequence;
            if (step.member) {
                members.set(...step.member);
                quorum.emit('addMember', ...step.member);
            }
            if (step.type === 'leave' && step.id) {
                members.delete(step.id);
                quorum.emit('removeMember', step.id);
            }
            if (step.type === 'attempt') data.recordAttempt();
            if (step.type === 'ack') data.markLastAttemptAsSuccessful();
            collection.emit(step.type === 'ack' ? 'summaryAck' : 'default', { sequenceNumber: step.sequence });
            if (step.type === 'op') data.numRuntimeOps++;
            if (step.type === 'noop') data.numNonRuntimeOps++;
            data.lastOpSequenceNumber = step.sequence;
            reason = null;
            runner.run();
            return { election: election.serialize(), reason, idleTime: runner.idleTime,
                runtimeOps: data.numRuntimeOps, nonRuntimeOps: data.numNonRuntimeOps,
                lastSummary: data.lastSuccessfulSummary.refSequenceNumber };
        });
        const serializedExpected: unknown = JSON.parse(JSON.stringify(expected));
        return { steps, expected: serializedExpected };
    } finally {
        Date.now = original;
        runner.dispose();
    }
}

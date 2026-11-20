"""Check channel traffic and quantify the bubbles from CASE=channels traces."""
import argparse
import csv
import json
from collections import Counter
from pathlib import Path


def audit(directory):
    jobs = list(csv.DictReader((directory / 'channel_cycles.csv').open()))
    events = list(csv.DictReader((directory / 'channel_events.csv').open()))
    assert jobs and events, 'Empty channel trace'
    act_bits = (4, 8, 4, 8, 16, 8, 16)
    job_index = 0
    acts_left = weights_left = 0
    issue_index = act_count = weight_count = issues_due = 0
    totals = Counter()
    uninterrupted = []
    for event in events:
        e = {k: int(v, 16 if k.endswith('_hex') else 10) for k, v in event.items()}
        command = e['cmd_valid'] and e['cmd_ready']
        weight = e['weight_valid'] and e['weight_ready']
        act = e['act_valid'] and e['act_ready']
        # Per-stream quotas decide ownership even on a command edge.
        old_act = bool(act and acts_left)
        old_weight = bool(weight and weights_left)
        eligible = False
        if issue_index < issues_due:
            tile, within = divmod(issue_index, phases * contexts)
            if ac > 1:
                phase, ctx = divmod(within, contexts)
            else:
                ctx, phase = divmod(within, phases)
            act_index = (tile * ws + (ctx if ws > 1 else 0)) * phases + phase
            weight_index = tile * ac + (ctx if ac > 1 else 0)
            needs_act = act_count <= act_index
            needs_weight = weight_count <= weight_index
            eligible = (act_count + old_act > act_index and
                        weight_count + old_weight > weight_index)
            if eligible:
                assert (e['tile'], e['context'], e['phase']) == (tile, ctx, phase)
                if needs_act or needs_weight:
                    key = 'both' if needs_act and needs_weight else 'act' if needs_act else 'weight'
                    totals['same_edge_issue_' + key] += 1
        assert e['issue'] == eligible, ('issue eligibility', e['cycle'], job_index, issue_index)
        issue_index += int(eligible)
        totals['act_accepts'] += int(act)
        totals['weight_accepts'] += int(weight)
        if command:
            assert issue_index == issues_due, 'Command accepted before previous final issue'
            if old_act or old_weight:
                key = 'both' if old_act and old_weight else 'act' if old_act else 'weight'
                totals['turnover_with_old_' + key] += 1
            acts_left -= old_act
            weights_left -= old_weight
            assert acts_left == weights_left == 0, (job_index, acts_left, weights_left)
            assert act == e['act_valid'] and weight == e['weight_valid'], 'Beat refused on command edge'
            act = act and not old_act
            weight = weight and not old_weight
            j = jobs[job_index]
            assert int(j['cmd_accept']) == e['cycle']
            totals['cmd_with_both_operands' if act and weight else
                   'cmd_with_act_only' if act else 'cmd_with_weight_only' if weight else
                   'cmd_without_operands'] += 1
            if act and weight:
                assert int(j['first_issue']) == e['cycle'] + 1, 'Bubble after both first beats'
                if job_index:
                    previous = jobs[job_index-1]
                    if int(previous['same_config']) and int(previous['next_cmd_gap']) == 0:
                        assert int(previous['next_issue_bubbles']) == 0, 'Compatible turnover bubble'
                        totals['zero_bubble_turnovers'] += 1
            os, ws, ac = (int(j[key]) for key in ('os', 'ws', 'as'))
            contexts = max(ws, ac)
            phases = act_bits[int(j['precision'])] // 4
            acts_left = os * ws * phases
            weights_left = os * ac
            issues_due = os * contexts * phases
            issue_index = act_count = weight_count = 0
            job_index += 1
            uninterrupted.append(True)
        if (acts_left and not e['act_valid']) or (weights_left and not e['weight_valid']):
            uninterrupted[-1] = False
        if act:
            assert acts_left > 0, 'Unbound or excess activation plane'
            acts_left -= 1
            act_count += 1
        if weight:
            assert weights_left > 0, 'Unbound or excess weight address'
            weights_left -= 1
            weight_count += 1
        if e['input_active'] and not e['issue'] and e['psum_valid_hex']:
            totals['output_cycles_while_issue_stalled'] += 1
        if e['issue'] and (not e['act_ready'] or not e['weight_ready']):
            totals['issue_cycles_despite_input_not_ready'] += 1
        assert not e['cmd_valid'] or e['cmd_ready'], 'Command offered outside ready window'
    assert job_index == len(jobs) and acts_left == weights_left == 0
    assert issue_index == issues_due
    assert totals['output_cycles_while_issue_stalled'] > 0
    assert totals['issue_cycles_despite_input_not_ready'] > 0
    assert totals['zero_bubble_turnovers'] >= 210
    assert all(totals['same_edge_issue_' + key] for key in ('act', 'weight', 'both'))
    assert all(totals['turnover_with_old_' + key] for key in ('act', 'weight', 'both'))
    assert all(totals[key] for key in ('cmd_with_both_operands', 'cmd_with_act_only',
                                       'cmd_with_weight_only', 'cmd_without_operands'))
    for j, supplied in zip(jobs, uninterrupted):
        if supplied:
            phases = act_bits[int(j['precision'])] // 4
            issue_count = int(j['os']) * max(int(j['as']), int(j['ws'])) * phases
            assert int(j['last_issue']) - int(j['first_issue']) + 1 == issue_count, ('intra-job bubble', j)
    totals['continuous_input_jobs_without_issue_gaps'] = sum(uninterrupted)
    switched = Counter()
    same = Counter()
    acceptance_after_last_output = Counter()
    for index, j in enumerate(jobs[:-1]):
        bubbles = int(j['next_issue_bubbles'])
        (same if int(j['same_config']) else switched)[bubbles] += 1
        if 'prior_drain' in jobs[index+1]:
            horizon = int(jobs[index+1]['prior_drain'])
            if horizon > int(j['last_issue']):
                acceptance_after_last_output[int(jobs[index+1]['cmd_accept']) - horizon] += 1
        elif not int(j['same_config']) and int(j['last_output']) >= 0:
            acceptance_after_last_output[int(jobs[index+1]['cmd_accept']) - int(j['last_output'])] += 1
    # The pending command must enter on the earliest safe edge.
    assert set(acceptance_after_last_output) == {0}, acceptance_after_last_output
    report = dict(jobs=len(jobs), traffic=dict(totals),
                  same_config_issue_bubbles=dict(sorted(same.items())),
                  different_config_issue_bubbles=dict(sorted(switched.items())),
                  different_cmd_accept_minus_previous_last_output=dict(acceptance_after_last_output))
    (directory / 'channel_audit.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='CASE=channels data directory')
    audit(parser.parse_args().directory)

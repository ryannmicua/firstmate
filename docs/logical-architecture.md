# Logical architecture

Firstmate coordinates autonomous work through a supervising agent, delegated workers, explicit authority, and durable records.
This document describes the system in concepts that do not depend on a particular technology stack.
It describes behavior that is currently shipped and makes no claim about proposed or in-progress integrations.
The [supervisor contract](../AGENTS.md) owns binding role, authority, and task rules; this guide explains their stack-independent design.
The [technical architecture companion](architecture.md) describes how this system is implemented today.

## Operating model

The captain states an outcome and retains authority over the scope and decisions that require human judgment.
Firstmate is the captain's point of contact, turns requests into bounded work, supervises execution, and reports verified outcomes.
Workers take responsibility for assigned tasks and work independently within the scope and limits they receive.
Optional secondmates supervise work within their own declared domain and return results through the firstmate that routed the work.
Each role is explicit, and project content or a worker's local instructions do not grant additional authority.

## Authority and boundaries

The captain owns project intent, high-impact choices, destructive authorization, and merge approval, except where the captain has explicitly granted a bounded standing delegation.
Firstmate may make routine orchestration choices inside that authority, such as how to divide work, which worker to assign, and how to supervise or recover it.
Workers may choose execution details within their assignment but may not widen its scope, bypass its safety limits, or authorize a consequential action for themselves.
Firstmate ordinarily reads and coordinates project work while workers make changes in isolated copies.
Any exception that lets firstmate directly change a project requires concrete captain authorization for that project and operation.
Independent tasks may proceed concurrently when their ownership is clear and the chosen delivery path can safely reconcile their overlap.

## Tasks and delegation

Work has two logical shapes: a task that changes a project and must be delivered, or an investigation that returns findings without changing the project.
An assignment carries the captain's intent, the firstmate's task scope, allowed actions, relevant context, acceptance conditions, and the expected form of the result.
Each worker is accountable for its assigned task or charter and reports progress, obstacles, questions, and outcomes to its supervisor.
Workers do not contact the captain as a parallel route around firstmate.
Investigation findings and other task records remain available after the temporary work setting is retired.
Delegation is useful when a task can be owned clearly; firstmate keeps shared decisions, true dependencies, and unsafe mutable conflicts under one accountable owner.

## Durable knowledge and events

Firstmate keeps durable information at the scope where it belongs.
Captain preferences and fleet operations belong to the relevant firstmate home, while project-specific knowledge belongs with the project and task-specific evidence belongs with its task.
Information is shared between homes only within an explicit scope, so a delegated domain does not become authority over unrelated work.
Conversations are temporary and cannot be the only record of an open decision, promised action, handoff, or outcome that must survive a restart.
Durable events announce that something may need attention, but they are signals rather than authoritative descriptions of current state.
Firstmate reconciles those signals against current task and delivery facts before deciding what happened.
Actionable notifications remain available until their handling is acknowledged, so interruption or restart does not silently erase work.

## Decisions

Firstmate resolves routine choices and other questions inside its delegated authority, and brings choices it cannot resolve, consequential actions, and policy conflicts to the captain.
An escalation records the question and the authority needed to answer it, and dependent work remains pending until that answer is received.
The answer is attached to the open decision it resolves, rather than inferred from silence or an unrelated later status update.
A worker's request for a decision is not itself permission to take the action in question.

## Supervision and recovery

Supervision compares worker-reported progress with durable task records and observable delivery facts.
A worker's completion message is a claim to reconcile, not proof that the requested result landed or passed its required validation.
When execution stalls, stops, or becomes uncertain, firstmate recovers from the durable assignment and preserves the worker's project state.
Ambiguous liveness or ownership is treated as unknown, not as evidence that work is safe to discard or replace.
Cleanup follows successful delivery or a confirmed decision that the work may end, and never removes unlanded work merely to make recovery easier.
The same task records support ordinary continuation after a restart, keeping the work identity and its unresolved decisions intact.

## Validation and delivery

Each project and task has an explicit delivery posture that determines the required review, validation, and integration steps.
Firstmate selects that posture when accepting the work and carries it through assignment, verification, and completion.
Workers may report that their changes are ready, while the authorized supervisor verifies the required evidence and ensures any final integration follows the granted merge authority.
An investigation report can be delivered while it leaves a decision for the captain, but the investigation is not safely retired until its report exists and its decision obligations pass the completion gate.
A worker's contribution is ready only when its acceptance conditions and delivery requirements are satisfied, while the overall task remains open for any required review, landing, or decision.

## End-to-end flow

1. The captain requests an outcome, and firstmate identifies the scope, authority, and any ambiguity that must be resolved first.
2. Firstmate chooses whether the request is an investigation or a project change, then defines the assignment and its acceptance conditions.
3. Firstmate routes independent work to accountable workers in isolated project copies, keeping shared decisions and conflicting changes under clear ownership.
4. Workers execute within scope, record progress, and return findings or raise decisions through their supervisor.
5. Firstmate reconciles events with current state, supervises stalled or interrupted work, and escalates only the decisions that exceed its authority.
6. Firstmate checks the required evidence, follows the task's delivery posture, and reports the result and any remaining decision to the captain.
7. Firstmate retires temporary work only after the outcome is safely delivered or the task is explicitly ended, preserving durable knowledge and unresolved obligations.

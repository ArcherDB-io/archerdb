# ArcherDB Walkthrough (Node.js)

Code from the [top-level README.md](../../README.md) collected into a single runnable project.
## Walkthrough

Here's what this project does.

## 1. Insert initial position

This project inserts an initial GeoEvent for a tracked entity.

## 2. Update positions

It then upserts multiple GeoEvents to represent a movement path.

## 3. Validate latest position

It queries the latest position by UUID and validates the final stop.

## 4. Delete entity

Finally, it deletes the entity and verifies the delete took effect.

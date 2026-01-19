import os
import glob
import datetime
import shutil

def resolve_conflicts():
    # Find all sync conflict files
    conflict_files = []
    for root, dirs, files in os.walk("."):
        if ".git" in root:
            continue
        for file in files:
            if "sync-conflict" in file:
                conflict_files.append(os.path.join(root, file))

    print(f"Found {len(conflict_files)} conflict files outside .git/")

    for conflict_path in conflict_files:
        # Determine base filename
        # Pattern: name.sync-conflict-date-time-id.ext or name.sync-conflict-date-time-id
        # We need to find the base name by removing the sync-conflict part
        
        # Split by .sync-conflict
        parts = conflict_path.split(".sync-conflict-")
        if len(parts) != 2:
            print(f"Skipping malformed conflict filename: {conflict_path}")
            continue
            
        base_part = parts[0]
        suffix_part = parts[1]
        
        # The suffix usually contains the extension if the original had one
        # But looking at the file list:
        # CLAUDE.sync-conflict-... .md -> CLAUDE.md
        # LICENSE.sync-conflict-... -> LICENSE
        
        # If suffix_part has an extension after the ID, we need to append it?
        # Example: 20260117-203154-SOI2IMM.md
        
        suffix_split = suffix_part.split(".")
        extension = ""
        if len(suffix_split) > 1:
            extension = "." + ".".join(suffix_split[1:])
            
        base_path = base_part + extension
        
        if not os.path.exists(base_path):
            print(f"Base file missing for {conflict_path}, keeping conflict file as is (or renaming it?)")
            # If base is missing, we might want to rename conflict to base?
            # But usually this means the file was deleted on one side.
            # For now, let's just log it.
            continue
            
        # Compare timestamps
        base_mtime = os.path.getmtime(base_path)
        conflict_mtime = os.path.getmtime(conflict_path)
        
        base_time_str = datetime.datetime.fromtimestamp(base_mtime).strftime('%Y-%m-%d %H:%M:%S')
        conflict_time_str = datetime.datetime.fromtimestamp(conflict_mtime).strftime('%Y-%m-%d %H:%M:%S')
        
        if base_mtime >= conflict_mtime:
            print(f"Keeping BASE: {base_path} ({base_time_str}) >= {conflict_path} ({conflict_time_str})")
            os.remove(conflict_path)
        else:
            print(f"Replacing BASE with CONFLICT: {base_path} ({base_time_str}) < {conflict_path} ({conflict_time_str})")
            shutil.move(conflict_path, base_path)

if __name__ == "__main__":
    resolve_conflicts()

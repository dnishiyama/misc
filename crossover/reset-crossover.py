#!/usr/bin/env python3
import os
import shutil
import re
import plistlib
from datetime import datetime

print("Resetting Crossover FirstRunDate...")
# Set os path
userPath = os.path.expanduser('~')

# Open plist
with open(f'{userPath}/Library/Preferences/com.codeweavers.CrossOver.plist', 'rb') as f:
    pl = plistlib.load(f)


# Set first run date to correct time
pl['FirstRunDate'] = datetime.utcnow()

# Save plist
with open(f'{userPath}/Library/Preferences/com.codeweavers.CrossOver.plist', 'wb') as f:
    plistlib.dump(pl, f)

print("Resetting Crossover bottles...")
while True:
    # Get bottle name
    bottle_name = input("Enter the bottle name: ")

    # Define paths
    regfile = os.path.expanduser(f"~/Library/Application Support/CrossOver/Bottles/{bottle_name}/system.reg")
    bakfile = regfile + ".bak"

    # Create backup
    shutil.copy2(regfile, bakfile)
    print(f"Backup created: {bakfile}")

    # Compile the regex pattern
    pattern = re.compile(r"\[Software\\\\CodeWeavers\\\\CrossOver\\\\cxoffice\] [0-9]*")

    # Read the file and search for match line
    with open(regfile, 'r') as f:
        lines = f.readlines()

    match_line_num = None
    for i, line in enumerate(lines):
        if pattern.search(line):
            match_line_num = i
            break

    # If match is found
    if match_line_num is not None:
        print(f"Match found at line {match_line_num + 1}.")
        for line in lines[match_line_num:match_line_num + 5]:
            print(line, end='')

        resp = input("Do you want to delete these lines (delete to reset bottle)? (y/n): ").strip().lower()
        if resp == 'y':
            new_lines = lines[:match_line_num] + lines[match_line_num + 5:]
            with open(regfile, 'w') as f:
                f.writelines(new_lines)
            print("Lines deleted.")
        else:
            print("Deletion canceled.")
    else:
        print("No match found.")

    # Ask if we should continue
    resp = input("Do you want to reset another bottle? (y/n): ").strip().lower()
    if resp != 'y':
        print("CrossOver trial reset.")
        break
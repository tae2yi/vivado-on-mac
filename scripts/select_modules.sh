#!/bin/bash

# Interactive module selection for Vivado installer
# Usage: select_modules.sh <template_config> <output_config>

if [ $# -ne 2 ]; then
	echo "Usage: $0 <template_config> <output_config>" >&2
	exit 1
fi

template="$1"
output="$2"

if [ ! -f "$template" ]; then
	echo "Error: Template config not found: $template" >&2
	exit 1
fi

# Extract Modules= line
modules_line=$(grep "^Modules=" "$template")
if [ -z "$modules_line" ]; then
	echo "Error: Modules= line not found in template" >&2
	exit 1
fi

modules_value="${modules_line#Modules=}"

# Create temp directory for working files
tmpdir="/tmp/select_modules_$$"
mkdir -p "$tmpdir" || exit 1
trap "rm -rf '$tmpdir'" EXIT

# Split tokens by comma, extract menu items (uppercase-starting names)
echo "$modules_value" | tr ',' '\n' > "$tmpdir/all_tokens.txt"

# Create menu_items file: line_number|name|token_index
# We need to track which token index each menu item came from
token_index=0
menu_index=0
while IFS= read -r token; do
	# Extract name (everything before last colon)
	name="${token%:*}"
	# Trim whitespace
	name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

	# Check if name starts with uppercase letter
	first_char=$(echo "$name" | cut -c1)
	if [ -n "$first_char" ] && echo "$first_char" | grep -q '[A-Z]'; then
		menu_index=$((menu_index + 1))
		echo "$menu_index|$name|$token_index" >> "$tmpdir/menu_items.txt"
	fi
	token_index=$((token_index + 1))
done < "$tmpdir/all_tokens.txt"

menu_count=$(wc -l < "$tmpdir/menu_items.txt" | tr -d ' ')
if [ "$menu_count" -eq 0 ]; then
	echo "Error: No selectable items found" >&2
	exit 1
fi

# The catalog order is arbitrary, so list the menu alphabetically and renumber
LC_ALL=C sort -t'|' -k2,2 "$tmpdir/menu_items.txt" | awk -F'|' '{print NR "|" $2 "|" $3}' > "$tmpdir/menu_sorted.txt"
mv "$tmpdir/menu_sorted.txt" "$tmpdir/menu_items.txt"

# Display menu
echo ""
echo "Vivado and Vitis HLS are always installed and cannot be deselected."
echo "Nothing else is installed unless selected here."
echo "Every family adds several GB of disk."
echo ""

while IFS='|' read -r menu_num name token_idx; do
	echo "  $menu_num) $name"
done < "$tmpdir/menu_items.txt"
echo ""

# Input validation loop
while true; do
	echo -n "Enter the numbers of the items to install, separated by spaces (for example: 4 7), then press Enter: "
	if ! read -r input_line; then
		exit 1
	fi

	# Check for empty input
	if [ -z "$input_line" ]; then
		echo "Error: Please enter at least one number."
		continue
	fi

	# Validate input contains only numbers and spaces
	if ! echo "$input_line" | grep -q '^[0-9 ]*$'; then
		echo "Error: Invalid input. Please enter numbers separated by spaces."
		continue
	fi

	# Validate each number is in valid range and deduplicate
	valid=true
	selected_menu_nums=""
	for num in $input_line; do
		if [ "$num" -lt 1 ] 2>/dev/null || [ "$num" -gt "$menu_count" ] 2>/dev/null; then
			echo "Error: Number $num is out of range (1-$menu_count)."
			valid=false
			break
		fi
		# Deduplicate by checking if already in selected list
		if ! echo " $selected_menu_nums " | grep -q " $num "; then
			selected_menu_nums="$selected_menu_nums $num"
		fi
	done

	if [ "$valid" = false ]; then
		continue
	fi

	# Display selected items for confirmation
	echo ""
	echo "Selected items:"
	for menu_num in $selected_menu_nums; do
		name=$(sed -n "${menu_num}p" "$tmpdir/menu_items.txt" | cut -d'|' -f2)
		echo "  - $name"
	done
	echo ""

	# Confirmation prompt
	while true; do
		echo -n "Install exactly these items [Y/n]? "
		if ! read -r confirm; then
			exit 1
		fi

		case "$confirm" in
			""|[yY]|[yY][eE][sS])
				# Build set of selected token indices
				selected_token_indices=""
				for menu_num in $selected_menu_nums; do
					token_idx=$(sed -n "${menu_num}p" "$tmpdir/menu_items.txt" | cut -d'|' -f3)
					selected_token_indices="$selected_token_indices $token_idx"
				done

				# Regenerate Modules= line with proper flags
				{
					new_modules="Modules="
					token_index=0
					first=true
					while IFS= read -r token; do
						if [ "$first" = true ]; then
							first=false
						else
							new_modules="$new_modules,"
						fi

						# Extract name (everything before last colon)
						name="${token%:*}"
						name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

						# Check if this token index is in selected list
						found=false
						for idx in $selected_token_indices; do
							if [ "$idx" -eq "$token_index" ]; then
								found=true
								break
							fi
						done

						if [ "$found" = true ]; then
							new_modules="$new_modules$name:1"
						else
							new_modules="$new_modules$name:0"
						fi

						token_index=$((token_index + 1))
					done < "$tmpdir/all_tokens.txt"
					echo "$new_modules"
				} > "$tmpdir/new_modules.txt"

				# Write output config file, replacing the Modules= line in place
				awk -v f="$tmpdir/new_modules.txt" 'BEGIN { getline line < f } /^Modules=/ { print line; next } { print }' "$template" > "$output"

				exit 0
				;;
			[nN]|[nN][oO])
				# Go back to input prompt
				break
				;;
			*)
				echo "Please answer y or n."
				;;
		esac
	done
done

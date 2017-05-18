package provide tincr.io.device 0.0
package require Tcl 8.5
package require tincr.cad.design 0.0
package require tincr.cad.device 0.0
package require tincr.cad.util 0.0

namespace eval ::tincr:: {
    namespace export \
	create_xml_family_info 
}

# #########################################
#           Family Info Notes:
# ######################################### 
# This Tcl script is used to generate FamilyInfo.xml files for RapidSmith2 or other external tools.
# The Family Info augments the XDLRC file with additional information about devices. Currently,
# some hand-edits are required for things that cannot be automatically generated using Vivado Tcl
# commands.
#
# Series7:
# -------
# 1.) Alternate site pin mappings: When a site type is changed in Vivado to an alternate type, the
#     pins may be renamed. We cannot determine the which pins are renamed for series7 devices, and
#     so the user must do this manually. NOT APPICABLE TO ULTRASCALE
# 2.) Some sites in series 7 return invalid alternate types. Invalid alternate types need to be removed by hand
#     by looking at the alternate types in the device browser GUI
# 3.) The series7 primitive defs in Tincr contain sites that do not appear in the Tcl interface. At some point, we need
#     to remove these primitive defs, but for now we can add them to the end of the family info with limited info.
# 4.) Compatible types need to be added for compatible sites with more than one BEL (generally SLICEL->SLICEM  and
#     IOB sites)
#
# UltraScale:
# -----------
# 1.) Compatible types need to be added for compatible sites with more than one BEL (generally SLICEL->SLICEM  and
#     IOB sites). Most compatible types for single-BEL sites can be generated though.
#     - Under SLICEL
#     <compatible_types>
#       <compatible_type>SLICEM</compatible_type>
#     </compatible_types>
#
#     - UNDER HRIO
#     <compatible_types>
#       <compatible_type>HPIOB</compatible_type>
#     </compatible_types>

# global variable set to 1 if a family is within the series7 of devices  
set is_series7 0

## Helper function to return the suffix of a split string. For example,
#   the following call to this function [suffix a/b/c/d "/"] will return "d".
#
# @param string String to split
# @param token Token to split the specified string on
proc suffix { string token } {
	return [lindex [split $string $token] end]
} 

## Returns a list of routing muxes in the specified site
#
# @param site Site object
proc get_routing_bel_names {site} {
	set bels [get_bels -of $site]
	set rmuxes [list]
	
	foreach pip [get_site_pips -of $site -quiet] {
		set name [lindex [split $pip ":"] 0]
		
		if {[lsearch $bels "$name"] == -1} {
			lappend rmuxes [lindex [split $name "/"] 1]
		}
	}
	
	return [lsort -unique $rmuxes]
}

## Writes the group that the specified site belongs to. 
#   Possible groups include SLICE, IOB, DSP, BRAM, and FIFO.
#   If the given site does not fit into any group, nothing will be 
#   printed to output file
#
# @param site_name Name of the site object
# @param fileout Output XML file
proc write_site_group {site_name site_type fileout} {
    if {[string first SLICE $site_name 0] == 0} {
        puts $fileout "      <is_slice/>"
    } elseif {[string first IOB $site_name 0] == 0} {
        puts $fileout "      <is_iob/>"
    } elseif {[string first DSP $site_name 0] == 0} {
        puts $fileout "      <is_dsp/>"
    } elseif {[string first RAMB $site_type] != -1} {
        puts $fileout "      <is_bram/>"
        # for RAMBFIFO sites, mark the site as a fifo as well
        if {[string first FIFO $site_type] != -1} {
            puts $fileout "      <is_fifo/>"
        }
    } elseif {[string first FIFO $site_type] != -1} {
        puts $fileout "      <is_fifo/>"
    }
}

## Returns a list of "test" BELs in the specified site. Test 
#   BELs are not returned from the function call "get_bels -of $site"
#   and so have to be obtained a different way.
#
# @param site Site object to get the test bels of
proc get_test_bels {site} {
    
    set test_bels [list]
    set bel_set [list] 
    
    # Find all BEL names based on the BEL pins
    foreach bel_pin [get_bel_pins -of $site] {
        regexp {.+/(.+)/.+} [get_property NAME $bel_pin] -> bel_name
        ::struct::set add bel_set $bel_name
    }
    
    # Add all BEL names that aren't returned from [get_bels -of $site] to the list of test BELs
    foreach bel_name $bel_set {
        if {[get_bels $site/$bel_name -quiet] == ""} {
            lappend test_bels $bel_name
        }
    }
    
    return $test_bels
}


## Writes the family info XML for the specified site. 
#   NOTE: this function assumes the site type has been already set before
#   calling this function.
#
# @param site Site object
# @param type Type of the site object
# @param is_alt 1 if the site is an alternate-only type. 0 otherwise.
# @param fileout File handle to the output XML file
# @param compatible_list Optional parameter specifying a list of compatible sites
# @param vsrt_bels_to_add A list of BELs that can't be extracted through Tcl, but need to
#   be added because they exist in the primitive definitions of the XDLRC (created from VSRT)
proc process_site {site type is_alt compatible_list fileout vsrt_bels_to_add } {
    
    puts $fileout "    <site_type>"
    puts $fileout "      <name>$type</name>"
    write_site_group $site $type $fileout
    
    # Write compatible types 
    if { [llength $compatible_list] != 0 } {
        print_compatible_sites $compatible_list $fileout
    }
    
    # Write alternate types for default sites 
    if {$is_alt == 0} { 
        print_alternate_types $site $fileout
    }
    
    # Look through all the BELs in the site. Print the name and type, and store any inout pins
    set inout_correction_map [dict create]
    
    puts $fileout "      <bels>"
    foreach bel [get_bels -of $site] {
        
        set bel_name [suffix $bel "/"]
        set bel_type [get_property TYPE $bel]
        
        # print the name, type, and routethroughs for the bel
        puts $fileout "        <bel>"
        puts $fileout "          <name>$bel_name</name>"
        puts $fileout "          <type>$bel_type</type>"
        
        print_routethroughs $bel $fileout
        puts $fileout "        </bel>"
        
        # Look for INOUT pins which need to be corrected for later
        set inout_pins [get_bel_pins -of $bel -filter DIRECTION==INOUT -quiet]
        if {[llength $inout_pins] > 0} {
            dict set inout_correction_map $bel_name $inout_pins
        }
    }
    
    # Add all test BELs to the XML and mark them as test BELs
    foreach test_bel [get_test_bels $site] {
        puts $fileout "        <bel>"
        puts $fileout "          <name>$test_bel</name>"
        puts $fileout "          <type>$test_bel</type>"
        puts $fileout "          <is_test/>"
        puts $fileout "        </bel>"
    }
    
    # Add the new BELs from VSRT
    foreach added_bel $vsrt_bels_to_add {
        set toks [split $added_bel ":"]
        set bel_name [lindex $toks 0]
        set bel_type [lindex $toks 1]
        
        puts $fileout "        <bel>"
        puts $fileout "          <name>$bel_name</name>"
        puts $fileout "          <type>$bel_type</type>"
        puts $fileout "        </bel>"
    }
    
    puts $fileout "      </bels>"
    
    # print the corrections to the XML file
    puts $fileout "      <corrections>"
    # write the INOUT pin corrections
    print_inout_pin_corrections $inout_correction_map $fileout
    
    #print any routing mux corrections
    print_routing_mux_corrections [get_routing_bel_names $site] $fileout
    
    puts $fileout "      </corrections>"
    puts $fileout "    </site_type>"
}

## Prints the compatible types of a site to the family info XML file.
#
# @param compatible_list List of compatible sites to print
# @param XML file handle
#
proc print_compatible_sites {compatible_list fileout} {
    puts $fileout "      <compatible_types>"
    foreach compatible_type $compatible_list {
        puts $fileout "        <compatible_type>$compatible_type</compatible_type>" 
    }
    puts $fileout "      </compatible_types>"
}

## Prints the alternate types for a site to the XML file 
#
# @param Site object
# @param XML file handle
proc print_alternate_types {site fileout} {
    global is_series7
    set alternate_types [get_property ALTERNATE_SITE_TYPES $site]     
    if { [llength $alternate_types] != 0 } {
        puts $fileout "      <alternatives>"
        foreach type $alternate_types {
            puts $fileout "        <alternative>"
            puts $fileout "          <name>$type</name>"
            
            # for series7 devices, add pinmap placeholders so users know where to add alternate type pin mappings
            if {$is_series7} {
                puts $fileout "          <pinmaps>"
                puts $fileout "          </pinmaps>"
            }
            
            puts $fileout "        </alternative>"
        }
        puts $fileout "      </alternatives>"
    }
}

# Prints the routethrough connections for LUT BELs. This function
#   assumes that the input pin names for LUTs are "A1-A6", and that the 
#   output pin name for a LUT is either "O5" or "O6". If this assumption
#   does not hold, then the function is invalid and will need to be re-implemented.
#
# @param bel Bel to print routethroughs for
# @param filout XML file handle
proc print_routethroughs {bel fileout} {
    set size 0
    set bel_type [get_property TYPE $bel]

    # Match LUT types against two possble patterns (they differ between series7 and ultrascale)
    set is_lut [expr { [regexp {.*([5,6])LUT$} $bel_type -> size] || [regexp {.*LUT([5,6])$} $bel_type -> size]}]
        
    # If the BEL is a LUT, then create the routethrough connections in the XML
    if { $is_lut } {
        set out_pin "O$size"
        
        puts $fileout "          <routethroughs>"
        for {set i 1} {$i <= $size} {incr i} {
        puts $fileout "            <routethrough>"
        puts $fileout "              <input>A$i</input>"
        puts $fileout "              <output>$out_pin</output>"
        puts $fileout "            </routethrough>"
        }
        puts $fileout "          </routethroughs>"
    }
}

## Primitive definitions for Series7 devices mark INOUT pins as INPUT pins
#   for some reason. This function prints out the correction to mark those pins
#   as INOUT instead (the proper direction)
#
# @param inout_correction_map Map from a bel, to the inout pins on that bel
#
proc print_inout_pin_corrections {inout_correction_map fileout} {
    dict for {bel inout_pins} $inout_correction_map {
        foreach pin $inout_pins {
            puts $fileout "        <pin_direction>"
            puts $fileout "          <element>$bel</element>"
            puts $fileout "          <pin>[suffix $pin "/"]</pin>"
            puts $fileout "          <direction>inout</direction>"
            puts $fileout "        </pin_direction>"
        }
    }
}

## Prints the routing mux corrections to the XML file.
#   NOTE: polarity selectors are identified by looking for the keywork "INV" or "OPTINV."
#   If this assumption does not hold true, then this function will need to be re-implemented.
#
# @param routing_muxes A list of routing muxes in the current site
# @param fileout XML file handle
#
proc print_routing_mux_corrections {routing_muxes fileout} {
    foreach routing_mux $routing_muxes {
        # Check if the rmux is a strong or weak polarity selector
        set strong_polarity_selector 0
        set weak_polarity_selector 0
        
        if { [regex {^.*OPTINV.*} $routing_mux] } {
            set strong_polarity_selector 1
            
        } elseif { [regex {^.*INV.*} $routing_mux] } {
            set weak_polarity_selector 1
        }
        
        # print the corrections to the MXL file
        if {$strong_polarity_selector} {
            puts $fileout "        <polarity_selector> <name>$routing_mux</name> </polarity_selector>"
        } elseif {$weak_polarity_selector} {
            # add an XML comment for weak polarity selectors so the user know that these may be incorrect
            puts $fileout "        <polarity_selector> <name>$routing_mux</name> </polarity_selector> <!-- Weak selector -->"
        } else { 
            # if the rmux is not a polarity selector, mark it as a regular mux
            puts $fileout "        <modify_element> <name>$routing_mux</name> <type>mux</type> </modify_element>"
        }
    }
}

## Prints the family info XML header
#
# @param family Vivado family name
# @param fileout XML file handle
proc print_header_family_info {family fileout} {
    # print XML header 
    puts $fileout "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    puts $fileout "<device_description>"
    puts $fileout "  <family>$family</family>"
}

## Creates and returns a compatible type map (maps site type to a list of compatible types) 
#
# @param primary_type_map Primary type map created from tincr::sites unique
proc create_compatible_site_map {site_type_map alternate_site_set compute_extended} {
    # First, set all alternate-types as compatible with its corresponding default type
    set compatible_type_map [dict create]
    dict for {type site} $site_type_map {
        if {[::struct::set contains $alternate_site_set $type] == 0} {
            foreach alternate_type [get_property ALTERNATE_SITE_TYPES $site] {
                dict lappend compatible_type_map $alternate_type $type  
            }
        }
    }

    # Then, look for compatible types for single-BEL sites by experimentally placing cells
    # This only needs to happen once per family-info generation.
    if {$compute_extended} {    
        # create the cell -> site type map
        set supported_lib_cells [::tincr::get_supported_leaf_libcells]
        set cell_to_sitetype_map [create_cell_to_site_map $supported_lib_cells $site_type_map $alternate_site_set] 
    
        # create the reverse map site type -> cells that can be placed on the site 
        set sitetype_to_cell_map [dict create]
        dict for {cell site_type_list} $cell_to_sitetype_map {
            foreach site_type $site_type_list {
                dict lappend sitetype_to_cell_map $site_type $cell
            }
        }
        
        # for each site, go through and try to determine more compatible sitea 
        dict for {type site} $site_type_map {
                
            if { [llength [get_bels -of $site -quiet]] == 1 && [dict exists $sitetype_to_cell_map $type] } {
                set cell_list [dict get $sitetype_to_cell_map $type]
                
                # create a list of candidate sites that could possibly be compatible
                set candidate_sites [list]
                set i 0
                foreach cell $cell_list {
                    if {$i ==0} {
                        set candidate_sites [dict get $cell_to_sitetype_map $cell]
                        incr i
                    } else {
                        set candidate_sites [::struct::set intersect $candidate_sites [dict get $cell_to_sitetype_map $cell]]
                    }
                }
                
                # check if the candidates are valid compatible sites
                foreach candidate_type $candidate_sites {
                    
                    set candidate_cell_count  [llength [dict get $sitetype_to_cell_map $candidate_type]]
                    
                    # check to see if the candidate is a valid compatible site
                    if { $candidate_type != $type && $candidate_cell_count >= [llength $cell_list] } {
                        
                        # get the list of currently compatible site
                        set current_list [list]
                        if {[dict exists $compatible_type_map $type]} {
                            set current_list [dict get $compatible_type_map $type]
                        }
                        
                        # If the candidate is compatible, then add it to the compatible map
                        if {[lsearch $current_list $candidate_type] == -1} {
                            dict lappend compatible_type_map $type $candidate_type
                        }
                        
                        # For alternate-only compatible types, mark the default type as compatible as well.
                        if {[::struct::set contains $alternate_site_set $candidate_type] } {
                            set default_site [dict get $site_type_map $candidate_type]
                            reset_property MANUAL_ROUTING $default_site
                            set default_type [get_property SITE_TYPE $default_site]
                            
                            if {[lsearch $current_list $default_type] == -1} {
                                dict lappend compatible_type_map $type $default_type
                            }
                        }
                    }
                }
            }
        }
    }
    
    return $compatible_type_map
}

## Parses the VSRT "addedBels.txt" file for the current architecture,
#   and creates a map of BELs to add to the Family Info.
#
# @param family Vivado device family name
# @param vsrt_bels_file VSRT "addedBels.txt" file.
proc parse_vsrt_bels {family vsrt_bels_file} {
    # if no VSRT bels file is specified, return an empty dictionary
    if {$vsrt_bels_file == ""} {
        return [dict create]
    }
    
    # otherwise, parse the file and store the VSRT bel data into a dictionary
    set vsrt_bels_map [dict create]
    
    set infile [open $vsrt_bels_file r]
    set file_data [string trim [read $infile]]
    
    foreach line [split $file_data "\n"] {
        set toks [split $line]
        
        # throw an error an exit if the file is not in the correct format and exit
        if {[llength $toks] != 3} {
           puts "\nParse Error: Invalid file format for " $vsrt_bels_file
           exit
        }
        
        set family_name [lindex $toks 0]
        set site_name [lindex $toks 1]
        set bel_name [lindex $toks 2]
        
        # We only expect VCC and GND BELs in this file, 
        # if this is not the case, then throw an exception
        if {[string first "GND" $bel_name] != -1} {
            set type "GND"
        } elseif {[string first "VCC" $bel_name] != -1} {
            set type "VCC"
        } else {
            puts "[Parse Error]: The BELs in \"addedBels.txt\" should only be GND or VCC BELs. "
            puts "\t $bel_name does not match this pattern."
            exit
        }
        
        # only include added bels for the current family
        if {$family_name == $family} {
            dict lappend vsrt_bels_map $site_name ${bel_name}:$type
        }
    }
    
    return $vsrt_bels_map
}

## Creates a new familyInfo.xml file for the specified family
#   This XML file contains additional device information/corrections
#   that are not included in the XDLRC generated from <tincr::write_xdlrc>"()".
#
# @param filename Output XML file. If the file does not end in ".xml", then ".xml" will be appended.
# @param family The family to generate the family info for. Possible options include:
#  <p><ul>
#  <li> artix7 
#  <li> kintex7 
#  <li> virtex7 
#  <li> zynq 
#  <li> kintexu 
#  <li> kintexuplus
#  <li> virtexu 
#  <li> virtexuplus
#  <li> zynquplus
# </ul><p>
# @param vsrt_bels_file (Optional) The VSRT "addedBels.txt" file generated
#   while creating primitive defs in VSRT. If you don't know what this means, you can safely ignore it.
proc ::tincr::create_xml_family_info { filename family {vsrt_bels_file ""} } {

    catch { close_project -quiet  }
    
    # create the XML file
    set filename [::tincr::add_extension ".xml" $filename]    
    set fileout [open $filename w]
    
    # parse the addedBelsDirectory
    set vsrt_bel_map [parse_vsrt_bels $family $vsrt_bels_file]
    
    # print header
    print_header_family_info $family $fileout
    
    # Initialize variables
    set primary_set [list]
    set alternate_set [list]
    set unique_parts [tincr::get_parts_unique $family]
    set i 1
    global is_series7
    set is_series7 [expr {[string first "7" $family] != -1}] 
    
    # Iterate through each part in the family and print the site information
    puts $fileout "  <site_types>"
    foreach prt $unique_parts {
        puts "processing $prt ($i out of [llength $unique_parts])..."
        
        # open the part 
        link_design -part $prt -quiet
        
        # find the unique sites for the part 
        set site_types [tincr::sites unique 1]
        set site_type_map [lindex $site_types 0]
        set alternate_type_set [lindex $site_types 1]
        set compatible_type_map [create_compatible_site_map $site_type_map $alternate_type_set [expr {$i==1}]]
        
        # process the sites 
        dict for {type site} $site_type_map {
            # get the compatible list for the type
            set compatible_types [list]
            if {[dict exists $compatible_type_map $type]} {
                set compatible_types [dict get $compatible_type_map $type]
            }
            
            # get the list of VSRT bels to add
            set vsrt_bels [list]
            if {[dict exists $vsrt_bel_map $type]} {
                set vsrt_bels [dict get $vsrt_bel_map $type]
            }
            
            # generate the family info XML for the site
            if {[::struct::set contains $alternate_type_set $type]} {
                # Process alternate type
                if {[::struct::set contains $primary_set $type]} { 
                    puts "ASSUMPTION WRONG! Default site appears as alternate-only site in a later part: $prt $type $site"
                    exit
                }
                # If we haven't already processed the site, then create the XML for the family info
                if {[::struct::set contains $alternate_set $type] == 0} {
                    puts "\t ALTERNATE:$type -> $site"
                    # for alternate types, set the type before processing the site
                    reset_property MANUAL_ROUTING $site
                    set_property MANUAL_ROUTING $type $site
                    process_site $site $type 1 $compatible_types $fileout $vsrt_bels
                    ::struct::set add alternate_set $type
                }
            } else {
                # Process default (or primary) type
                if {[::struct::set contains $alternate_set $type]} {
                    puts "ASSUMPTION WRONG! Alternate type appears as default type in a later part"
                    exit
                }
                # If we haven't already processed the site, then create the XML for the family info
                if {[::struct::set contains $primary_set $type] == 0} {
                    puts "\t $type -> $site"
                    process_site $site $type 0 $compatible_types $fileout $vsrt_bels
                    ::struct::set add primary_set $type
                }
            }
        }
        incr i
        close_design -quiet
    }
    
    # print series 7 corrections
    # TODO: this should be removed ASAP by removing bad primitive defs from Tincr
    if {$is_series7 == 1} {
        print_series7_corrections $site_type_map $fileout
    }
    
    puts $fileout "  </site_types>"
        
    # print the ending tag and close the file
    puts $fileout "</device_description>"
    flush $fileout
    close $fileout
    
    puts "Successfully created $filename" 
    close_project -quiet
}

## Prints additional primitive site information for series 7 devices.
#   TODO: This is outdated. We need to remove some of the primitive defs
#   in the cache folder so that we no longer need this function
#
# @param site_type_map Map from site type to an instance of that site
# @param fileout XML file handle 
proc print_series7_corrections {site_type_map fileout} {
    #print sites that show up in Vivado, but don't actual exist via the TCL interface
    puts $fileout "\n<!-- Do the site types that don't appear in the tincr::sites::unique list -->\n"
    puts "Processing all other site types..."
    foreach site [tincr::sites::get_types] {
        if {![dict exists $site_type_map $site] } {
            printSingleBelPrimitiveList $site $fileout 
        }   
    }

    # Do the site types that appear in the XDLRC as primitive sites that the TCL interface doesn't know about
    # NOTE: Update the list below as needed 
    puts $fileout "\n\n\n<!-- Do the site types that appear in the XDLRC as primitive sites that aren't found in Vivado's TCL interface -->\n"

    set xdlrc_primitives [list CFG_IO_ACCESS GCLK_TEST_BUF MTBF2 PMV PMV2_SVT PMVBRAM PMVIOB]
    printSingleBelPrimitiveList $xdlrc_primitives $fileout

    # Do the site types that are needed but show up nowhere ... why do we need this  
    # NOTE: Update the list below as needed 
    puts $fileout "\n\n\n<!-- Do the site types that are needed but show up nowhere - not sure where they would come from so I add them here -->\n"

    set other [list DCI ]
    printSingleBelPrimitiveList $other $fileout
}

## For "filler" primitive sites, this function prints a skeleton version of the site
#   to the family info. This function is used for series 7 family info's only.
#
# @param sites A list of primitive sites to print
# @param fileout XML file handle
proc printSingleBelPrimitiveList {sites fileout} {

    foreach site $sites {
        puts $fileout "    <site_type> "
        puts $fileout "      <name>$site</name>"
        puts $fileout "      <bels>"
        puts $fileout "        <bel>"
        puts $fileout "          <name>$site</name>"
        puts $fileout "          <type>$site</type>"
        puts $fileout "        </bel>"
        puts $fileout "      </bels>"
        puts $fileout "    </site_type>"
    }
}

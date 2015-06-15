### Imports ###
package require Tcl       8.6
package require Tk        8.6
package require sqlite3   3.8.0.1
package require tablelist 5.13

tablelist::addBWidgetEntry

### sqlite3 ###
sqlite3 ts timesheetdb

ts eval {
  CREATE TABLE IF NOT EXISTS timesheet(
    week text,
    code text,
    status text,
    timetype text,
    type text,
    activity text,
    description text,
    date text,
    hours float
  )
}

### GUI ###
## Window
catch {destroy [winfo children .]}

set cur_dir [file join [pwd] [file dirname [info script]]]

wm title . "Timesheet Tool"
wm geometry . +100+100

## Menus
set menu .menu
menu $menu -tearoff 0

set m $menu.tools
menu $m -tearoff 0
$menu add cascade -label "Tools" -menu $m -underline 0
$m add command -label "Save" -command {save_timesheet} \
  -command {save_timesheet} -accelerator Ctrl+S
$m add command -label "Parked time" -command {export_parked} \
  -accelerator Ctrl+P
$m add command -label "Certain code" -command {export_by_code} \
  -accelerator Ctrl+Shift+C

bind . <Control-KeyPress-s> {save_timesheet}
bind . <Control-KeyPress-p> {export_parked}
bind . <Control-Shift-KeyPress-c> {export_by_code}

set m $menu.go
menu $m -tearoff 0
$menu add cascade -label "Go to" -menu $m -underline 0
$m add command -label "Current week" -command {ts_load "now"} \
  -accelerator Ctrl+W
$m add command -label "Four weeks before" -command {ts_load "4ago"} \
  -accelerator Ctrl+B
    
bind . <Control-KeyPress-W> {ts_load "now"}
bind . <Control-KeyPress-B> {ts_load "4ago"}

. configure -menu $menu

set m $menu.about
menu $m -tearoff 0
$menu add cascade -label "Help" -menu $m -underline 0
$m add command -label About -command {ts_about}

## Common procs
proc get_friday {date} {
  set w [clock format $date -format %u]
  set d [expr {5-$w >= 0 ? 5-$w : 12-$w}]
  set fdate [clock format [clock add $date $d days] -format {%d/%m/%Y}]
  return $fdate
}

proc reset_timesheet {} {
  set f .fup.right
  for {set a 1} {$a < 9} {incr a} {
    for {set b 1} {$b < 7} {incr b} {
      $f.$a$b configure -text 0.0
    }
  }
  .fdown.tab delete top bottom
  new_row
}

proc ts_load {time} {
  switch $time {
    "now" {
      set date [get_friday [clock scan now]]
    }
    "4ago" {
      set date [get_friday [clock scan "now 4 weeks ago"]]
    }
  }
  .fup.left.date configure -text $date
  down_update
}

proc down_update {} {
  set date [lindex [.fup.left.date configure -text] 4]
  set lines [ts eval {
    SELECT * FROM timesheet WHERE week = $date
    ORDER BY week, code, status, timetype, type, activity, description, date
  }]
  reset_timesheet
  if {$lines != ""} {
    set cline ""
    foreach {w c s tt t a des d h} $lines {
      set row [expr {[.fdown.tab size]-1}]
      set wday [clock format [clock scan $d -format {%d/%m/%Y}] -format %u]
      set day [expr {$wday > 5 ? $wday-6 : $wday+1}]
      if {"$w$c$s$tt$t$a$des" != $cline} {
        if {$cline != ""} {
          .fdown.tab insert $row [list $tt $t $c $a $s $des {*}$fweek]
        }
        set cline "$w$c$s$tt$t$a$des"
        set fweek [lrepeat 7 {}]
      }
      lset fweek $day $h
    }
    .fdown.tab insert $row [list $tt $t $c $a $s $des {*}$fweek]
  }
}

proc save_timesheet {} {
  set wk [lindex [.fup.left.date configure -text] 4]
  ts eval {DELETE FROM timesheet WHERE week = $wk}
  for {set i 0} {$i < [.fdown.tab size]} {incr i} {
    set details [lindex [.fdown.tab rowconfigure $i -text] 4]
    set repeats [lmap n [lrange $details 0 5] {set n '$n'}]
    set repeats [lreplace $repeats 5 5 [string map {, {}} [lindex $repeats 5]]]
    lassign $repeats tt type code act park desc
    if {$code == "''"} {continue}
    set repeats [list '$wk' $code $park $tt $type $act $desc]
    set days [lrange $details 6 12]
    set start [clock scan $wk -format {%d/%m/%Y}]
    for {set j [clock add $start -6 days]; set k 0} {$k < 8} {
      set j [clock add $j 1 day]
      incr k
    } {
      set dayhours [lindex $days $k]
      if {$dayhours == ""} {continue}
      set d [clock format $j -format "%d/%m/%Y"]
      ts eval "
        INSERT INTO timesheet VALUES([join $repeats {,}],'$d',$dayhours)
      "
      puts "[join $repeats ","],'$d',$dayhours"
    }
  }
  tk_messageBox -title Notice -message "Timesheet saved!"
}

## Calendar
proc calendar {w} {
  set cal ${w}cal
  catch {destroy $cal}
  toplevel $cal
  
  wm title $cal "Choose date"
  
  # proc to change the layout when month or year are changed
  proc date_adjust {cal dir {monthlist ""}} {
    set m [$cal.f.s1 get]
    if {$monthlist != "" && $m ni $monthlist} {
      tk_messageBox -title Error -message "Please insert a valid month."
      focus $cal
      return
    }
    set cmonth [lindex [split [date_format "01-$m-[$cal.f.s2 get]"] "/"] 1]
    set cyear [$cal.f.s2 get]
    if {$cyear < 1900 || $cyear > 9999} {
      tk_messageBox -title Error -message "Please insert a year between 1900 and 9999."
      focus $cal
      return
    }
    set cmonth [string trimleft $cmonth 0]
    incr cmonth $dir
    if {($cmonth == 0 && $dir == "-1") || ($cmonth == 13 && $dir == "+1")} {
      incr cyear $dir
      set cmonth [expr {$cmonth == 0 ? 12 : 1}]
      $cal.f.s2 set $cyear
    }
    cal_display $cal $cmonth $cyear
  }
  
  # proc to display the calendar layout
  proc cal_display {cal month year} {
    set canvas $cal.c
    $canvas delete all
    lassign [list 20 20 20 20 20] x0 x y dx dy
    set xmax [expr {$x0+$dx*6}]
    
    $canvas create rectangle 10 0 30 150 -outline "" -tag wkd
    $canvas create rectangle 130 0 150 150 -outline "" -tag wkd
    
    foreach i {S M T W T F S} {
      $canvas create text $x $y -text $i -fill blue
      incr x $dx
    }
    scan [clock format [clock scan $month/01/$year] -format %w] %d weekday
    set x [expr {$x0+$weekday*$dx}]
    incr y $dy
    set month [string trimleft $month 0]
    set nmax [number_of_days $month $year]

    for {set d 1} {$d <= $nmax} {incr d} {
      set id [$canvas create text $x $y -text $d -tag day]
      if {[format %02d $d] == [clock format [clock scan now] -format %d]
        && $month == [clock format [clock scan now] -format %m]
        && $year == [clock format [clock scan now] -format %Y]
      } {
        $canvas itemconfigure $id -fill red -tags {day cday}
      }
      incr x $dx
      if {$x > $xmax} {
        set x $x0
        incr y $dy
      }
    }
    $canvas itemconfigure wkd -fill #C4D1DF
    
    $canvas bind day <ButtonPress-1> {
      set item [%W find withtag current]
      set day [%W itemcget $item -text]
      if {$day eq ""} {break}
      if {[%W find withtag clicked] == ""} {
        if {"cday" ni [%W gettags $item]} {
          %W itemconfigure $item -fill green -tags {day clicked}
        } else {
          %W itemconfigure $item -fill green -tags {day clicked cday}
        }  
      } else {
        if {[%W find withtag clicked] == [%W find withtag cday]} {
          if {$item == [%W find withtag cday]} {
            break
          } else {
            %W itemconfigure $item -fill green -tags {day clicked}
            %W itemconfigure cday -fill red -tags {day cday}
          }
        } else {
          if {$item == [%W find withtag cday]} {
            %W itemconfigure clicked -fill black -tags {day}
            %W itemconfigure $item -fill green -tags {day cday clicked}
          } else {
            %W itemconfigure clicked -fill black -tags {day}
            %W itemconfigure $item -fill green -tags {day clicked}
          }
        }
      }
      set cal [winfo parent %W]
      $cal.f2.e delete 0 end
      $cal.f2.e insert end [date_format "$day-[$cal.f.s1 get]-[$cal.f.s2 get]"]
    }    
    
    $canvas bind day <Double-ButtonPress-1> {
      set item [%W find withtag clicked]
      set day [%W itemcget $item -text]
      if {$day eq ""} {break}
      set cal [winfo parent %W]
      pick_date $cal [date_format "$day-[$cal.f.s1 get]-[$cal.f.s2 get]"]
    }
  }
  
  # proc to convert alphabetic date to numeric
  proc date_format {date} {
    return [clock format [clock scan $date -format {%d-%B-%Y}] -format {%d/%m/%Y}]
  }
  
  # proc to insert chosen date (through entry or double-click) to main window
  proc pick_date {cal {cdate ""}} {
    if {$cdate eq ""} {
      set cdate [$cal.f2.e get]
    }
    puts $cal
    if {$cal == ".cal"} {
      set cdate [clock scan $cdate -format {%d/%m/%Y}]
      set fdate [get_friday $cdate]
      .fup.left.date configure -text $fdate
      down_update
    } else {
      set e [winfo parent $cal]
      $e delete 0 end
      $e insert end $cdate
    }
    cal_exit $cal
  }
  
  # proc to close calender
  proc cal_exit {cal} {
    focus [winfo parent $cal]
    destroy $cal   
  }
  
  proc number_of_days {month year} {
    if {$month == 12} {
      set month 1
      incr year
    }
    clock format [clock scan "[incr month]/01/$year 1 day ago"] -format %d
  }
  
  lassign [split [clock format [clock scan now] -format "%d-%m-%Y"] "-"] d m y
  
  array set months {
    01 January
    02 February
    03 March
    04 April
    05 May
    06 June
    07 July
    08 August
    09 September
    10 October
    11 November
    12 December
  }
  set monthlist [lmap {a b} [array get months] {set b}]
  pack [frame $cal.f]
  ttk::spinbox $cal.f.s1 -values $monthlist -width 10 -wrap 1
  ttk::spinbox $cal.f.s2 -from 1900 -to 9999 -validate key \
    -validatecommand {string is integer %P} -command [list date_adjust $cal 0]
  bind $cal.f.s1 <<Decrement>> [list date_adjust $cal -1 $monthlist]
  bind $cal.f.s1 <<Increment>> [list date_adjust $cal +1 $monthlist]
  bind $cal.f.s1 <KeyPress-Return> [list date_adjust $cal 0 $monthlist]
  bind $cal.f.s2 <KeyPress-Return> [list date_adjust $cal 0 $monthlist]
  $cal.f.s1 set $months($m)
  $cal.f.s2 set $y
  pack $cal.f.s1 -side left -fill both -padx 10 -pady 10
  pack $cal.f.s2 -side left -fill both -padx 10 -pady 10
  
  set canvas [canvas $cal.c -width 160 -height 160 -background #F0F0F0]
  pack $cal.c
  pack [frame $cal.f2] -side left -padx 10 -pady 10
  ttk::entry $cal.f2.e -textvariable fulldate -width 20 -justify center
  pack $cal.f2.e -padx 10 -pady 10
  bind $cal.f2.e <KeyPress-Return> [list pick_date $cal]
  $cal.f2.e delete 0 end
  $cal.f2.e insert end "$d/$m/$y"
  pack [ttk::button $cal.f2.b1 -text "OK" -command [list pick_date $cal]] -side left \
    -padx 20
  pack [ttk::button $cal.f2.b2 -text "Cancel" -command [list cal_exit $cal]] -side left \
    -padx 20
  cal_display $cal $m $y
}

### Main window
pack [frame .fup] -side top -fill x -anchor n -pady 5
pack [frame .fdown] -side top -fill both -anchor n -pady 5 -expand 1

pack [frame .fup.left] -side left -fill x -anchor w -padx 5
pack [frame .fup.right] -side right -fill x -anchor e -padx 5

grid [label .fup.left.date -text [get_friday [clock scan now]]] -row 0 -column 0
bind .fup.left.date <ButtonPress-1> {calendar .}

set f .fup.left
grid [label $f.c -text "Chargeable (C)" -justify left] -row 1 -column 0 -sticky w
grid [label $f.p -text "Authorized Project (P)" -justify left] -row 2 -column 0 -sticky w
grid [label $f.n -text "Non-Chargeable (N)" -justify left] -row 3 -column 0 -sticky w
grid [label $f.t -text "Total" -justify left] -row 4 -column 0 -sticky w
grid [label $f.r -text "Regular (R)" -justify left] -row 5 -column 0 -sticky w
grid [label $f.o -text "Overtime (O)" -justify left] -row 6 -column 0 -sticky w
grid columnconfigure $f 0 -minsize 300

set f .fup.right
grid [label $f.headerSat -text "Sat"] -row 0 -column 1
grid [label $f.headerSun -text "Sun"] -row 0 -column 2
grid [label $f.headerMon -text "Mon"] -row 0 -column 3
grid [label $f.headerTue -text "Tue"] -row 0 -column 4
grid [label $f.headerWed -text "Wed"] -row 0 -column 5
grid [label $f.headerThu -text "Thu"] -row 0 -column 6
grid [label $f.headerFri -text "Fri"] -row 0 -column 7
grid [label $f.headerTot -text "Total"] -row 0 -column 8

bind $f.headerTot <Configure> {wm minsize . [winfo width .] [winfo height .]}

proc sum_update {} {
  set f .fup.right
  for {set a 1} {$a < 8} {incr a} {
    set total 0.0
    for {set b 1} {$b < 4} {incr b} {
      set ctext [lindex [$f.$a$b configure -text] 4]
      set total [expr {$total+$ctext}]
    }
    $f.${a}4 configure -text $total -font "Arial 9 bold"
  }
  
  for {set b 1} {$b < 7} {incr b} {
    set total 0.0
    for {set a 1} {$a < 8} {incr a} {
      set ctext [lindex [$f.$a$b configure -text] 4]
      set total [expr {$total+$ctext}]
    }
    $f.8$b configure -text $total -font "Arial 9 bold"
  }
}

for {set a 1} {$a < 9} {incr a} {
  grid columnconfigure $f [expr {$a-1}] -minsize 50
  for {set b 1} {$b < 7} {incr b} {
    set font [expr {($b == 4 || $a == 8) ? "Arial 9 bold" : "Arial 9"}]
    grid [label $f.$a$b -text 0.0 -font $font] -row $b -column $a
  }
}

set f .fdown

scrollbar $f.s -command [list $f.tab yview]

tablelist::tablelist $f.tab -columns {
  6 "TT"            center
  8 "Type"          center
  8 "Code"          center
  7 "Act"           center
  6 "Park"          center
  15 "Description"  center
  4 "S"             center
  4 "S"             center
  4 "M"             center
  4 "T"             center
  4 "W"             center
  4 "T"             center
  4 "F"             center
  7 "Total"         center
} -stretch all -background white -yscrollcommand [list $f.s set] \
  -arrowstyle sunken8x7 -showarrow 1 -resizablecolumns 0 \
  -selecttype cell -showeditcursor 0 -showseparators 1 \
  -stripebackground #C4D1DF -editendcommand tsvalidation -selectmode extended \
  -showarrow 1 -arrowstyle sunken8x7 -labelcommand tablelist::sortByColumn
  
$f.tab columnconfigure 0 -editable yes
$f.tab columnconfigure 1 -editable yes
$f.tab columnconfigure 2 -editable yes
$f.tab columnconfigure 3 -editable yes
$f.tab columnconfigure 4 -editable yes
$f.tab columnconfigure 5 -editable yes -align left -labelalign center
$f.tab columnconfigure 6 -sortmode real -editable yes -formatcommand format_time \
  -background gray80
$f.tab columnconfigure 7 -sortmode real -editable yes -formatcommand format_time \
  -background gray80
$f.tab columnconfigure 8 -sortmode real -editable yes -formatcommand format_time
$f.tab columnconfigure 9 -sortmode real -editable yes -formatcommand format_time
$f.tab columnconfigure 10 -sortmode real -editable yes -formatcommand format_time
$f.tab columnconfigure 11 -sortmode real -editable yes -formatcommand format_time
$f.tab columnconfigure 12 -sortmode real -editable yes -formatcommand format_time
$f.tab columnconfigure 13 -sortmode real -editable no -formatcommand format_time

proc tsvalidation {table row col text} {
  switch $col {
    0 {return [format_tt $text]}
    1 {return [format_type $text]}
    2 {
      set code [format_code $text]
      if {$code == 24484112 || $code == 22087682} {
        $table cellconfigure $row,1 -text "P"
      }
      return $code
    }
    4 {return [format_bool $text]}
    default {return $text}
  }
}

proc format_tt {val} {
  if {[string tolower $val] in [list r o]} {
    return [string toupper $val]
  } else {
    return "R"
  }
}

proc format_type {val} {
  if {$val == ""} {return $val}
  if {[string tolower $val] in [list c p n]} {
    return [string toupper $val]
  } else {
    return ""
  }
}

proc format_code {val} {
  if {$val == ""} {return $val}
  if {![string is integer $val]} {
    set ret ""
    switch -nocase $val {
      da {set ret 24484112}
      tr {set ret 22087682}
      default {}
    }
    return $ret
  } elseif {[string length $val] != 8} {
    return [string range $val 0 7]
  } else {
    return $val
  }
}

proc format_bool {val} {
  if {$val == ""} {return $val}
  if {[string tolower $val] in [list y n]} {
    return [string toupper $val]
  } else {
    return ""
  }
}

proc format_time {val} {
  if {[string is double $val] && $val != ""} {
    return [format %.1f $val]
  } else {
    return ""
  }
}

proc new_row {} {
  .fdown.tab insert end [list R {*}[lrepeat 13 {}]]
}

proc top_update {column} {
  set tts [lindex [.fdown.tab columnconfigure 0 -text] end]
  set types [lindex [.fdown.tab columnconfigure 1 -text] end]
  set vals [lindex [.fdown.tab columnconfigure $column -text] end]
  
  array set sums {
    C 0.0
    P 0.0
    N 0.0
    R 0.0
    O 0.0
  }
  
  foreach tt $tts type $types val $vals {
    if {$val == ""} {set val 0}
    set sums($tt) [expr {$sums($tt)+$val}]
    if {$type != ""} {
      set sums($type) [expr {$sums($type)+$val}]
    }
  }
  array set row {
    C 1
    P 2
    N 3
    R 5
    O 6
  }
  set f .fup.right
  set col [expr {$column-5}]
  foreach {key val} [array get sums] {
    $f.$col$row($key) configure -text $val
  }
}

proc total_update {row} {
  set sum 0
  set f .fdown.tab
  for {set i 6} {$i < 13} {incr i} {
    set v [lindex [$f cellconfigure $row,$i -text] 4]
    if {$v == ""} {continue}
    set sum [expr {$sum+$v}]
  }
  $f cellconfigure $row,13 -text $sum
}

new_row
down_update

bind $f.tab <<TablelistCellUpdated>> {
  lassign %d x y
  if {$y >= 6} {
    top_update $y
    total_update $x
    sum_update
  }
  if {$y in {0 1}} {
    for {set i 6} {$i < 13} {incr i} {
      top_update $i
    }
  }
  if {
    [expr {$x+1}] == [%W size] && 
    [lindex %d 1] != 0 &&
    [lindex [%W cellconfigure [join %d ,] -text] 4] ne ""
  } {
    new_row
  }
}

bind $f.tab <<TablelistSelect>> {
  set cur [%W curcellselection]
  #puts [tablelist::entrypathSubCmd %W]
  # %W cellselection clear $cur end
  # %W cellselection clear 0,0 end
  # %W cellselection set active
  # %W cellselection anchor active
  # %W cellselection set $cur  
}

pack $f.tab -fill both -expand 1 -side left -anchor n
pack $f.s -fill both -side right -anchor n

focus .

### Reports ###
proc export_by_code {} {
  set w .ebe
  catch {destroy $w}
  toplevel $w
  
  wm title $w "Select code"
  
  proc begin_export {} {
    set code [.ebe.ent get]
    if {![regexp -- {^\d{8}$} $code]} {
      tk_messageBox -title Error -icon error -message "Invalid code! Please make sure the code is 8 digit long."
      focus .ebe
      return
    }
    
    set types {{"Text files"   .txt}}

    set file [tk_getSaveFile -filetypes $types -parent .ebe \
      -initialfile "Export for $code.txt" -initialdir [pwd] \
      -defaultextension .txt]
    if {$file == ""} {return}

    set f [open $file w]
    set lines [ts eval {SELECT * FROM timesheet WHERE code = $code}]
    if {$lines != ""} {
      puts $f "Week\tEngagement Code\tParked?(Y/N)\tTimeType\tType\tActivity\tDescription\tDate\tHours"
      foreach {w c s tt t a des d h} $lines {
        puts $f "$w $c $s $tt $t $a $des $d $h"
      }
      tk_messageBox -title Complete -icon info -message "Export complete!"
    } else {
      tk_messageBox -title Error -icon error -message "No entries matching provided code found!"
    }
    close $f
    focus .ebe
  }
  
  pack [label $w.lab -text "Enter the engagement code below:"] -side top \
    -padx 10 -pady 10
  pack [entry $w.ent] -side top -pady 5
  bind $w.ent <KeyPress-Return> {begin_export}
  pack [ttk::button $w.bok -text "OK" -command {begin_export}] -side left \
    -padx 5 -pady 5
  pack [ttk::button $w.bcn -text "Cancel" -command [list close_export $w]] \
    -side right -padx 5 -pady 5
}

proc export_parked {} {
  set w .ep
  catch {destroy $w}
  toplevel $w

  wm title $w "Select date range"
  
  proc begin_export {} {
    set start [.ep.f1.start get]
    set end [.ep.f1.end get]
    if {[regexp -- {^(?:start|\d{2}/\d{2}/\d{4})$} $start] || 
        [regexp -- {^(?:end|\d{2}/\d{2}/\d{4})$} $end]
    } {
      tk_messageBox -title Error -icon error -message "Invalid range!"
      focus .ep
      return
    }
    
    set types {{"Text files"   .txt}}

    set file [tk_getSaveFile -filetypes $types -parent .ebe \
      -initialfile "Export parked time from $start to $end.txt" -initialdir [pwd] \
      -defaultextension .txt]
    if {$file == ""} {return}
    set f [open $file w]
    
    set lines [ts eval {SELECT * FROM timesheet WHERE status = 'Y'}]
    if {$lines != ""} {
      puts $f "Week\tEngagement Code\tParked?(Y/N)\tTimeType\tType\tActivity\tDescription\tDate\tHours"
      catch {set start [clock scan $start -format {%d/%m/%Y}]}
      catch {set end [clock scan $end -format {%d/%m/%Y}]}
      foreach {w c s tt t a des d h} $lines {
        if {($w <= $start || $start == "start") &&
            ($w >= $end || $end == "end")} {
          puts $f "$w $c $s $tt $t $a $des $d $h"
        }
      }
      tk_messageBox -title Complete -icon info -message "Export complete!"
    } else {
      tk_messageBox -title Error -icon error -message "No entries matching provided code found!"
    }
    close $f
    focus .ep
  }

  pack [label $w.lab -text "Enter the date range below:"] -side top \
    -padx 10 -pady 10
  pack [frame $w.f1] -side top
  pack [frame $w.f2] -side bottom
  pack [entry $w.f1.start -width 10] -side left -padx 5 -pady 5
  pack [entry $w.f1.end -width 10] -side right -padx 5 -pady 5
  bind $w.f1.start <ButtonPress-1> [list calendar "%W."]
  bind $w.f1.end <ButtonPress-1> [list calendar "%W."]
  $w.f1.start insert end "start"
  $w.f1.end insert end "end"
  pack [ttk::button $w.f2.bok -text "OK" -command {begin_export}] -side left \
    -padx 5 -pady 5
  pack [ttk::button $w.f2.bcn -text "Cancel" -command [list close_export $w]] \
    -side right -padx 5 -pady 5
}

proc close_export {w} {
  if {[winfo exists $w]} {
    wm withdraw $w
    destroy $w
    focus .
  }
}

proc ts_about {} {
  set w .abt
  catch {destroy $w}
  toplevel $w
  wm title $w "About Timesheet Tool"
  
  label $w.l1 -text "Author:"
  label $w.l2 -text "Git:"
  label $w.l3 -text "Jerry Yong"
  label $w.l4 -text ""

}

### To Do
# === Tablelist
# Fix sorting

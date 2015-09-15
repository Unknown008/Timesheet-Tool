### Imports ###
package require Tcl            8.6
package require Tk             8.6
package require sqlite3        3.8.0.1
package require tablelist      5.13
package require twapi          4.1.27

### Restore previous instance if any ###
set exist [twapi::find_windows -text "Timesheet Tool"]
if {$exist != ""} {
  foreach win $exist {
    if {[twapi::get_window_real_class $win] eq "TkTopLevel"} {
      twapi::show_window $win -activate
      exit
    }
  }
}

set path [file join [pwd] tclkit.ico]
if {![file exists $path]} {
  set exec [lindex [file split $::argv0] end-1]
  set path [file join [pwd] $exec tclkit.ico]
  file copy $path [pwd]
  set hand [twapi::load_icon_from_file tclkit.ico]
  twapi::systemtray addicon $hand select
  file delete tclkit.ico
} else {
  set hand [twapi::load_icon_from_file tclkit.ico]
  twapi::systemtray addicon $hand select
}

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

ts eval {
  CREATE TABLE IF NOT EXISTS alarm(
    name text,
    repeat text,
    weekday int,
    time text,
    state text,
    header text,
    description text
  )
}

ts eval {
  CREATE TABLE IF NOT EXISTS shortcuts(
    alias text,
    code text,
    tt text
  )
}

ts eval {
  CREATE TABLE IF NOT EXISTS config(
    tablename text,
    timestamp text
  )
}

if {[ts eval {SELECT * FROM config}] == ""} {
  set timestamp [clock scan now]
  ts eval {INSERT INTO config VALUES("alarm", $timestamp)}
  ts eval {INSERT INTO config VALUES("shortcuts", $timestamp)}
  ts eval {
    INSERT INTO alarm VALUES("Friday Buzz","Y","Fri","17:00","Off","Alarm!","It is time to complete and submit your timesheet!")
  }
  ts eval {INSERT INTO shortcuts VALUES("da", "24484112", "P")}
  ts eval {INSERT INTO shortcuts VALUES("tr", "22087682", "P")}
}

### GUI ###
## Window
catch {destroy [winfo children .]}

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
$m add command -label "Alarm settings" -command {set_alarm} \
  -accelerator Ctrl+A
$m add command -label "Shortcuts" -command {show_shortcuts} \
  -accelerator Ctrl+Shift+S
$m add command -label "SQL Query" -command {sql_query}
$m add separator
$m add command -label "Close" -command {exit} -accelerator Ctrl+Q

bind . <Control-KeyPress-s> {save_timesheet}
bind . <Control-KeyPress-p> {export_parked}
bind . <Control-KeyPress-C> {export_by_code}
bind . <Control-KeyPress-S> {show_shortcuts}
bind . <Control-KeyPress-q> {exit}

set m $menu.go
menu $m -tearoff 0
$menu add cascade -label "Go to" -menu $m -underline 0
$m add command -label "Current week" -command {ts_load "now"} \
  -accelerator Ctrl+W
$m add command -label "Four weeks before" -command {ts_load "4ago"} \
  -accelerator Ctrl+B
    
bind . <Control-KeyPress-w> {ts_load "now"}
bind . <Control-KeyPress-b> {ts_load "4ago"}

set m $menu.about
menu $m -tearoff 0
$menu add cascade -label "Help" -menu $m -underline 0
$m add command -label About -command {ts_about}

. configure -menu $menu

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
  new_row .fdown.tab ts
}

proc ts_load {time} {
  switch $time {
    "4ago" {
      set date [get_friday [clock scan "now 4 weeks ago"]]
    }
    default {
      set date [get_friday [clock scan now]]
    }
  }
  .fup.left.f.date configure -text $date
  down_update
  sum_update
}

proc down_update {} {
  set date [lindex [.fup.left.f.date configure -text] 4]
  set lines [ts eval {
    SELECT * FROM timesheet WHERE week = $date
    ORDER BY week, code, status, timetype, type, activity, description, date
  }]
  reset_timesheet
  set tab .fdown.tab
  if {$lines != ""} {
    set cline ""
    set clist ""
    foreach {w c s tt t a des d h} $lines {
      set row [expr {[$tab size]-1}]
      set wday [clock format [clock scan $d -format {%d/%m/%Y}] -format %u]
      set day [expr {$wday > 5 ? $wday-6 : $wday+1}]
      if {"$w$c$s$tt$t$a$des" != $cline} {
        if {$cline != ""} {
          $tab insert $row [list {*}$clist {*}$fweek]
        }
        set clist [list $tt $t $c $a $s $des]
        set cline "$w$c$s$tt$t$a$des"
        set fweek [lrepeat 7 {}]
      }
      lset fweek $day $h
    }
    $tab insert $row [list $tt $t $c $a $s $des {*}$fweek]
    for {set i 6} {$i <= 13} {incr i} {
      top_update $i
    }
    for {set i 0} {$i <= [expr {$row+1}]} {incr i} {
      total_update $i
    }
  }
}

proc save_timesheet {} {
  set wk [lindex [.fup.left.f.date configure -text] 4]
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
    }
  }
  tk_messageBox -title "Notice" -message "Timesheet saved!"
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
        && [format %02d $month] == [clock format [clock scan now] -format %m]
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
      .fup.left.f.date configure -text $fdate
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

wm protocol . WM_DELETE_WINDOW min_to_tray

proc min_to_tray {} {
  catch {destroy [winfo children .]}
  wm withdraw .
}

proc select {id event pos time} {
  switch $event {
    select {restore_win $id}
    default {}
  }
}

proc restore_win {id} {
  wm state . normal
  raise .
  focus .
}

### Main window ###
pack [frame .fup] -side top -fill x -anchor n -pady 5
pack [frame .fdown] -side top -fill both -anchor n -pady 5 -expand 1

pack [frame .fup.left] -side left -fill x -anchor w -padx 5
pack [frame .fup.right] -side right -fill x -anchor e -padx 5

grid [frame .fup.left.f] -row 0 -column 0
pack [button .fup.left.f.l -relief flat -command {go_week -1} -text "<"] -side left -anchor w
pack [label .fup.left.f.date -text [get_friday [clock scan now]]] -side left -anchor n
pack [button .fup.left.f.r -relief flat -command {go_week 1} -text ">"] -side left -anchor e
bind .fup.left.f.date <ButtonPress-1> {calendar .}

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
    $f.${a}4 configure -text [format %.1f $total] -font {{Segeo UI} 9 bold}
  }
  
  for {set b 1} {$b < 7} {incr b} {
    set total 0.0
    for {set a 1} {$a < 8} {incr a} {
      set ctext [lindex [$f.$a$b configure -text] 4]
      set total [expr {$total+$ctext}]
    }
    $f.8$b configure -text [format %.1f $total] -font {"Segeo UI" 9 bold}
  }
}

for {set a 1} {$a < 9} {incr a} {
  grid columnconfigure $f [expr {$a-1}] -minsize 50
  for {set b 1} {$b < 7} {incr b} {
    set font [expr {($b == 4 || $a == 8) ? {"Segeo UI" 9 bold} : {"Segeo UI" 9}}]
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
  -stripebackground "#C4D1DF" -editendcommand tsvalidation -selectmode extended \
  -labelcommand tablelist::sortByColumn -editstartcommand select_all

$f.tab configcolumnlist {
  0 -editable yes
  1 -editable yes
  2 -editable yes
  3 -editable yes
  4 -editable yes
  5 -editable yes
  5 -align left
  5 -labelalign center
  6 -sortmode command
  6 -editable yes
  6 -formatcommand format_time
  6 -background gray80
  6 -sortcommand cust_sort
  7 -sortmode command
  7 -editable yes
  7 -formatcommand format_time
  7 -background gray80
  7 -sortcommand cust_sort
  8 -sortmode command
  8 -editable yes
  8 -formatcommand format_time
  8 -sortcommand cust_sort
  9 -sortmode command
  9 -editable yes
  9 -formatcommand format_time
  9 -sortcommand cust_sort
  10 -sortmode command
  10 -editable yes
  10 -formatcommand format_time
  10 -sortcommand cust_sort
  11 -sortmode command
  11 -editable yes
  11 -formatcommand format_time
  11 -sortcommand cust_sort
  12 -sortmode command
  12 -editable yes
  12 -formatcommand format_time
  12 -sortcommand cust_sort
  13 -sortmode command
  13 -editable no
  13 -formatcommand format_time
  13 -sortcommand cust_sort
}

proc cust_sort {a b} {
  if {[string compare $a $b] == 0} {return 0}
  lassign {0 0} inta intb
  if {![string is double $a]} {set inta 1}
  if {![string is double $b]} {set intb 2}

  # $inta + $intb =
  # 0 => both are numbers
  # 1 => only intb is number, so $intb is larger
  # 2 => only inta is number, so $inta is larger
  # 3 => none are numbers, both are blanks, already handled
  switch [expr {$inta+$intb}] {
    0 {return [expr {$a > $b ? 1 : -1}]}
    1 {return -1}
    2 {return 1}
  }
}

proc tsvalidation {table row col text} {
  switch $col {
    0 {return [format_tt $text]}
    1 {return [format_type $text]}
    2 {
      lassign [format_code $text] code type
      if {$type ne ""} {
        $table cellconfigure $row,1 -text $type
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
    set details [ts eval {SELECT * FROM shortcuts WHERE LOWER(alias) = LOWER($val)}]
    if {$details != ""} {
      lassign $details a ret t
    }
    return [list $ret $t]
  } elseif {[string length $val] != 8} {
    return [list [string range $val 0 7] ""]
  } else {
    return [list $val ""]
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

proc new_row {tab type} {
  switch $type {
    ts {$tab insert end [list R {*}[lrepeat 13 {}]]}
    alarm {$tab insert end [lrepeat 5 {}]}
    shortcut {$tab insert end [lrepeat 3 {}]}
  }
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
    $f.$col$row($key) configure -text [format %.1f $val]
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

bind $f.tab <<TablelistCellUpdated>> {
  lassign %d x y
  if {$y >= 6} {
    top_update $y
    total_update $x
    sum_update
  } elseif {$y in {0 1}} {
    for {set i 6} {$i < 13} {incr i} {
      top_update $i
    }
  }
  if {
    [expr {$x+1}] == [%W size] && 
    $x != 0 &&
    [lindex [%W cellconfigure [join %d ,] -text] 4] ne ""
  } {
    new_row %W ts
  }
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

    set lines [ts eval {SELECT * FROM timesheet WHERE code = $code}]
    if {$lines != ""} {
      set file [tk_getSaveFile -filetypes $types -parent .ebe \
        -initialfile "Export for $code.txt" -initialdir [pwd] \
        -defaultextension .txt]
      if {$file == ""} {return}

      set f [open $file w]
      puts $f "Week\tEngagement Code\tParked?(Y/N)\tTimeType\tType\tActivity\tDescription\tDate\tHours"
      foreach {w c s tt t a des d h} $lines {
        puts $f "$w\t$c\t$s\t$tt\t$t\t$a\t$des\t$d\t$h"
      }
      tk_messageBox -title Complete -icon info -message "Export complete!"
      close $f
    } else {
      tk_messageBox -title Error -icon error -message "No entries matching provided code found!"
    }

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
    if {![regexp -- {^(?:start|\d{2}/\d{2}/\d{4})$} $start] || 
        ![regexp -- {^(?:end|\d{2}/\d{2}/\d{4})$} $end]
    } {
      tk_messageBox -title Error -icon error -message "Invalid range!"
      focus .ep
      return
    }
    
    set types {{"Text files"   .txt}}

    set lines [ts eval {SELECT * FROM timesheet WHERE status = 'Y'}]
    if {$lines != ""} {
      set file [tk_getSaveFile -filetypes $types -parent .ep \
        -initialfile "Export parked time from $start to $end.txt" -initialdir [pwd] \
        -defaultextension .txt]
      if {$file == ""} {return}
      set f [open $file w]
      
      puts $f "Week\tEngagement Code\tParked?(Y/N)\tTimeType\tType\tActivity\tDescription\tDate\tHours"
      catch {set start [clock scan $start -format {%d/%m/%Y}]}
      catch {set end [clock scan $end -format {%d/%m/%Y}]}
      foreach {w c s tt t a des d h} $lines {
        if {($w <= $start || $start == "start") &&
            ($w >= $end || $end == "end")} {
          puts $f "$w\t$c\t$s\t$tt\t$t\t$a\t$des\t$d\t$h"
        }
      }
      tk_messageBox -title Complete -icon info -message "Export complete!"
      close $f
    } else {
      tk_messageBox -title Error -icon error -message "No parked time found!"
    }
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

### Alarm settings ###
proc set_alarm {} {
  set w .alarm
  catch {destroy $w}
  toplevel $w
  
  wm geometry $w +200+200
  wm minsize $w 900 [winfo height $w]
  wm title $w "Alarm settings"
  pack [frame $w.f] -fill both -expand 1 -side top -anchor n
  set w $w.f
  
  scrollbar $w.s -command [list $w.tab yview]
  tablelist::tablelist $w.tab -columns {
    15 "Name (unique)"     center
    15 "Repeat (Y/N)"      center
    15 "Day (DDD)"         center
    15 "Time (hh:mm)"      center
    8 "On/Off"             center
    15 "Alert header"      center
    40 "Alert description" center
  } -stretch all -background white -yscrollcommand [list $w.s set] \
    -arrowstyle sunken8x7 -showarrow 1 -resizablecolumns 0 \
    -selecttype cell -showeditcursor 0 -showseparators 1 \
    -stripebackground "#C4D1DF" -editendcommand alarmval -selectmode extended \
    -labelcommand tablelist::sortByColumn
  
  $w.tab configcolumnlist {
    0 -editable yes
    1 -editable yes
    2 -editable yes
    3 -editable yes
    4 -editable yes
    0 -align left
    0 -labelalign center
    5 -labelalign center
    5 -align left
    5 -editable yes
    6 -labelalign center
    6 -align left
    6 -editable yes
  }
  
  set results [ts eval {SELECT * FROM alarm}]
  foreach {n r wd t s h d} $results {
    set row [expr {[$w.tab size]-1}]
    $w.tab insert $row [list $n $r $wd $t $s $h $d]
  }
  
  pack $w.tab -fill both -expand 1 -side left -anchor n
  pack $w.s -fill both -side right -anchor n
  
  new_row $w.tab alarm
  
  bind $w.tab <<TablelistCellUpdated>> {
    set listing [list]
    for {set i 0} {$i < [%W size]} {incr i} {
      set rowData [lindex [%W rowconfigure $i -text] end]
      if {"" ni $rowData} {
        lappend listing $rowData
      }
    }
    ts eval {DELETE FROM alarm}
    clear_alarm
    foreach line $listing {
      set data [join [lmap n $line {set n '$n'}] ","]
      ts eval "INSERT INTO alarm VALUES($data)"
      test_alarm
    }
  }
}

proc alarmval {table row col text} {
  switch $col {
    0 {return [format_an $table $col $text]}
    1 {return [format_ar $text]}
    2 {return [format_ad $text]}
    3 {return [format_at $text]}
    4 {return [format_as $text]}
    5 {return $text}
    6 {return $text}
  }
}

proc format_an {table col val} {
  set vals [lindex [$table columnconfigure $col -text] end]
  if {$val in $vals} {
    tk_messageBox -title Error -icon error -message "Please select a unique name!"
    return ""
  } else {
    new_row $table alarm
    return $val
  }
}

proc format_ar {val} {
  if {[string tolower $val] in [list y n]} {
    return [string toupper $val]
  } else {
    return ""
  }
}

proc format_ad {val} {
  if {[string tolower $val] in [list mon tue wed thu fri sat sun]} {
    return [string totitle $val]
  } else {
    return ""
  }
}

proc format_at {val} {
  if {[catch {set val [clock format [clock scan $val -format %H:%M] -format %H:%M]}]} {
    return ""
  } else {
    return $val
  }
}

proc format_as {val} {
  if {[string tolower $val] in [list on off]} {
    return [string totitle $val]
  } else {
    return ""
  }
}


proc test_alarm {} {
  puts testing_alarm
  set tests [ts eval {SELECT * FROM alarm WHERE state = 'On'}]
  foreach {n r w t s h d} $tests {
    set delay [expr {([clock scan "$w $t"]-[clock scan now])*1000}]
    if {$delay > 0} {
      after $delay [list ring_alarm $n]
    }
  }
}

proc ring_alarm {name} {
  lassign [ts eval {SELECT * FROM alarm WHERE name = $name}] n r w t s h d
  tk_messageBox -title $h -message $d
  if {$r eq "N"} {
    ts eval {UPDATE alarm SET state = 'Off' WHERE name = $name}
  } else {
    set delay [expr {([clock add [clock scan "$w $t"] 1 week]-[clock scan now])*1000}]
    after $delay [list ring_alarm $name]
  }
}

proc clear_alarm {} {
  set alarms [after info]
  foreach alarm $alarms {
    after cancel $alarm
  }
}

proc show_shortcuts {} {
  set w .shortcuts
  catch {destroy $w}
  toplevel $w
  
  wm geometry $w +200+200
  wm minsize $w 500 [winfo height $w]
  wm title $w "Timesheet shortcuts"
  pack [frame $w.f] -fill both -expand 1 -side top -anchor n
  set w $w.f
  
  scrollbar $w.s -command [list $w.tab yview]
  tablelist::tablelist $w.tab -columns {
    15 "Shortcut"       center
    15 "Code"           center
    15 "Type (C/P/N)"   center
  } -stretch all -background white -yscrollcommand [list $w.s set] \
    -arrowstyle sunken8x7 -showarrow 1 -resizablecolumns 0 \
    -selecttype cell -showeditcursor 0 -showseparators 1 \
    -stripebackground "#C4D1DF" -editendcommand shortcutval -selectmode extended \
    -labelcommand tablelist::sortByColumn
  
  $w.tab configcolumnlist {
    0 -editable yes
    1 -editable yes
    2 -editable yes
  }
  
  set results [ts eval {SELECT * FROM shortcuts}]
  foreach {s c t} $results {
    set row [expr {[$w.tab size]-1}]
    $w.tab insert $row [list $s $c $t]
  }
  
  pack $w.tab -fill both -expand 1 -side left -anchor n
  pack $w.s -fill both -side right -anchor n
  
  new_row $w.tab shortcut
  
  bind $w.tab <<TablelistCellUpdated>> {
    set listing [list]
    for {set i 0} {$i < [%W size]} {incr i} {
      set rowData [lindex [%W rowconfigure $i -text] end]
      if {"" ni $rowData} {
        lappend listing $rowData
      }
    }
    ts eval {DELETE FROM shortcuts}
    foreach line $listing {
      set data [join [lmap n $line {set n '$n'}] ","]
      ts eval "INSERT INTO shortcuts VALUES($data)"
    }
  }
}

proc shortcutval {table row col text} {
  switch $col {
    0 {return [format_sn $table $col $text]}
    1 {return [format_sc $text]}
    2 {return [format_st $text]}
  }
}

proc format_sn {table col val} {
  set vals [lindex [$table columnconfigure $col -text] end]
  if {$val in $vals} {
    tk_messageBox -title Error -icon error -message "Please select a unique name!"
    return ""
  } else {
    new_row $table shortcut
    return $val
  }
}

proc format_sc {val} {
  if {[string length $val] != 8} {
    return [string range $val 0 7]
  } else {
    return $val
  }
}

proc format_st {val} {
  if {[string tolower $val] in [list c p n]} {
    return [string toupper $val]
  } else {
    return ""
  }
}

### About ###
proc ts_about {} {
  set w .abt
  catch {destroy $w}
  toplevel $w
  
  wm geometry $w +200+200
  wm title $w "About Timesheet Tool"
  
  pack [frame $w.fm] -padx 10 -pady 10
  set w $w.fm
  
  grid [frame $w.fup] -row 0 -column 0
  
  label $w.fup.l1 -text "Author:" -justify left
  label $w.fup.l2 -text "Git:" -justify left
  label $w.fup.l3 -text "Wiki:" -justify left
  label $w.fup.l4 -text "Jerry Yong" -justify left
  label $w.fup.l5 -text "https://github.com/Unknown008/Timesheet-Tool.git" \
    -foreground blue -justify left -font {"Segeo UI" 9 underline}
  label $w.fup.l6 -text "https://github.com/Unknown008/Timesheet-Tool/wiki/Documentation" \
    -foreground blue -justify left -font {"Segeo UI" 9 underline}
  bind $w.fup.l5 <ButtonPress-1> {
    eval exec [auto_execok start] "https://github.com/Unknown008/Timesheet-Tool.git" &
  }
  bind $w.fup.l5 <ButtonPress-1> {
    eval exec [auto_execok start] "https://github.com/Unknown008/Timesheet-Tool/wiki/Documentation" &
  }
  bind $w.fup.l5 <Enter> {linkify %W 1}
  bind $w.fup.l5 <Leave> {linkify %W 0}
  bind $w.fup.l6 <Enter> {linkify %W 1}
  bind $w.fup.l6 <Leave> {linkify %W 0}
  
  grid $w.fup.l1 -row 0 -column 0 -sticky w
  grid $w.fup.l2 -row 1 -column 0 -sticky w
  grid $w.fup.l3 -row 2 -column 0 -sticky w
  grid $w.fup.l4 -row 0 -column 1 -sticky w
  grid $w.fup.l5 -row 1 -column 1 -sticky w
  grid $w.fup.l6 -row 2 -column 1 -sticky w
  grid columnconfigure $w 0 -minsize 50
  
  grid [labelframe $w.fdown -padx 2 -pady 2 -text "GNU General Public Licence" \
    -labelanchor n] -row 1 -column 0 -pady 10
  text $w.fdown.t -setgrid 1 \
    -height 17 -autosep 1 -background "#F0F0F0" -wrap word -width 60 \
    -font {"Segeo UI" 9} -relief flat
  pack $w.fdown.t -expand yes -fill both
  
  $w.fdown.t insert end "
    Timesheet Tool - Recording tool, making timesheet reconciliations easier!
    Copyright \u00A9 2015 Jerry Yong <jeryysk.stillwaters@gmail.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program. If not, see <http://www.gnu.org/licenses/>
  "
  $w.fdown.t configure -state disabled
  
  grid [ttk::button $w.b -text OK -command {abt_close}] -row 2 -column 0
  
  proc abt_close {} {
    destroy .abt
    focus .
  }
  focus .abt
}

proc linkify {w state} {
  $w configure -cursor [expr {$state ? "hand2" : "ibeam"}]
}

proc go_week {amt} {
  set d [lindex [.fup.left.f.date configure -text] 4]
  set newdate [get_friday [clock add [clock scan $d -format {%d/%m/%Y}] $amt week]]
  .fup.left.f.date configure -text $newdate
  down_update
  sum_update
}

proc select_all {w r c v} {
  after idle [list [$w entrypath] selection range 0 end]
  return $v
}

proc sql_query {} {
  set results [ts eval {SELECT 1 FROM timesheet}]
  if {[llength $results] < 1} {
    tk_messageBox -icon error -title Error -message "No data inserted yet!"
    return
  }
  set w .query
  catch {destroy $w}
  toplevel $w
  wm title .query "SQLite Query"
  wm geometry . +100+50
  set menu $w.menu
  menu $menu -tearoff 0
  $menu add command -label "Run" -command [list run_query $w]
  $menu add command -label "Export" -command [list export_results $w]
  
  bind $w <KeyPress-F5> [list run_query $w]
  
  $w configure -menu $menu
  
  ttk::notebook $w.note
  set n $w.note
  grid $n -row 0 -column 0 -sticky nsew
  
  ttk::notebook::enableTraversal $n
  
  ttk::frame $n.tableview -height 300 -width 300 -padding "5 5"
  $n add $n.tableview -text " Tableview "
  
  ttk::frame $n.sqlview -height 300 -width 300 -padding "5 5"
  $n add $n.sqlview -text " SQL "
  
  label $n.tableview.tablelab -text "Table:"
  ttk::combobox $n.tableview.tablecbox -values {timesheet alarm shortcurs config}
  
  grid $n.tableview.tablelab -row 0 -column 0 -padx 5 -pady 5
  grid $n.tableview.tablecbox -row 0 -column 1 -padx 5 -pady 5
  
  bind $n.tableview.tablecbox <<ComboboxSelected>> {update_tableview %W 1}
  
  pack [text $n.sqlview.text -yscrollcommand "$n.sqlview.s set"] -side left \
    -anchor ne -fill both -expand 1
  pack [scrollbar $n.sqlview.s -command "$n.sqlview.text yview"] -fill y -side left
  
  frame $w.sidepane -height 500 -width 10
  grid $w.sidepane -row 0 -column 1 -sticky nsew
  
  
  ttk::treeview $w.sidepane.tree -columns table -yscroll "$w.sidepane.vs set"
  $w.sidepane.tree heading \#0 -text "Tables"
  ttk::scrollbar $w.sidepane.vs -command "$w.sidepane.tree yview"
  
  $w.sidepane.tree column table -stretch 0 -width 10
  
  proc populate_tree {tree} {
    set tables [ts eval {SELECT name FROM sqlite_master WHERE type = 'table'}]
    foreach table $tables {
      set node [$tree insert {} end -text $table]
      set fields [ts eval {
        SELECT sql FROM sqlite_master
        WHERE type = 'table' AND name = $table
      }]
      regexp -- {\(([^()]+)\)} $fields - m
      set l [split $m ","]
      set fields [lmap x $l {set x "\[[lindex $x 0]\] ([lindex $x 1])"}]
      foreach field $fields {
        set id [$tree insert $node end -text $field]
      }
    } 
  }
   
  grid $w.sidepane.tree -row 0 -column 0 -sticky nsew
  grid $w.sidepane.vs   -row 0 -column 1 -sticky nsew
  
  frame $w.fdown -height 300 -width 500 -pady 5 -padx 5 -relief sunken
  grid $w.fdown -row 1 -column 0 -columnspan 2 -sticky nsew
  
  grid rowconfigure $w.sidepane 0 -weight 1
  grid rowconfigure $w 0 -weight 1
  grid columnconfigure $w 0 -weight 1
  
  populate_tree $w.sidepane.tree
  
  proc run_query {w} {
    upvar columns columns
    
    set tid [$w.note select]
    
    catch {destroy $w.fdown.s}
    catch {destroy $w.fdown.text}
    catch {destroy $w.fdown.t}
    catch {destroy $w.fdown.hs}
    
    if {[lindex [split $tid "."] end] == "sqlview"} {
      set query [$w.note.sqlview.text get 1.0 end]
      
      if {[regexp -all -nocase -- {\yFROM\y} $query] > 1} {
        pack [text $w.fdown.text] -side top -anchor ne -fill both
        $w.fdown.text insert end "Subqueries/multiple queries not allowed."
        return
      } elseif {[regexp -all -nocase -- {\yINTO\y} $query]} {
        pack [text $w.fdown.text] -side top -anchor ne -fill both
        $w.fdown.text insert end "Creation of tables not allowed."
        return
      }
      
      if {[catch {set results [ts eval $query]} err]} {
        pack [text $w.fdown.text] -side top -anchor ne -fill both
        $w.fdown.text insert end "$err"
        return
      } else {
        if {[regexp -nocase -- {select } $query]} {
          regexp -nocase -- {select\s+(.+)from} $query - fields
          set colnames [lmap {f s} [regexp -inline -all -nocase {(\[[^\]]+\]|[^, \n]+)(?:,|$)} [string trim $fields]] {set s "10 $s"}]
          scrollbar $w.fdown.s -command "$w.fdown.t yview"
          scrollbar $w.fdown.hs -command "$w.fdown.t xview" -orient horizontal
          if {[set sidx [lsearch $colnames "*\**"]] > -1} {
            set cols {}
            ts eval $query values {lappend cols $values(*); break}
            set colnames [lmap x [lindex $cols 0] {set x "10 $x"}]
          }
          set columns [lindex $cols 0]
          tablelist::tablelist $w.fdown.t -columns [join $colnames " "] \
            -stretch all -background white -yscrollcommand "$w.fdown.s set" \
            -resizablecolumns 1 -selecttype cell -showeditcursor 0 \
            -showseparators 1 -xscrollcommand "$w.fdown.hs set"
          grid $w.fdown.t -row 0 -column 0 -sticky nsew
          grid $w.fdown.s -row 0 -column 1 -sticky nsew
          grid $w.fdown.hs -row 1 -column 0 -sticky nsew
          
          foreach $columns $results {
            set vars [lmap x $columns {set $x}]
            $w.fdown.t insert end $vars
          }
        } else {
          pack [text $w.fdown.text] -side top -anchor ne -fill both
          $w.fdown.text insert end "Query successfully executed!"
        }
      }
    } else {
      set table [$w.note.tableview.tablecbox get]
      
      set ws [winfo children $w.note.tableview]
      set columns {}
      set param {}
      foreach field $ws {
        if {[regexp -- {fieldscbox\d+} $field]} {
          set toadd [$field get]
          if {$toadd == "*"} {
            set all [lindex [$field configure -values] 4]
            set all [lreplace $all 0 0]
            foreach item $all {lappend columns $item}
          } elseif {$toadd != ""} {
            lappend columns $toadd
          } else {
            continue
          }
        }
        set f [winfo parent $field]
        if {[regexp -- {fieldccond(\d+)} $field - s] &&
            [$field get] != "" &&
            [$f.fieldpcond$s get] != ""
        } {
          if {$param != ""} {
            set i $s
            while {$i > 0} {
              incr i -1
              if {[$f.fieldscbox$i get] != ""} {break}
            }
            append param " [$f.fieldcomp$i get] "
          }
          append param [$f.fieldscbox$s get] " [$field get] "  "'[string map {' ''} [$f.fieldpcond$s get]]'"
        }
        
      }

      set colnames [lmap x $columns {set x "10 $x"}]
      scrollbar $w.fdown.s -command "$w.fdown.t yview"
      scrollbar $w.fdown.hs -command "$w.fdown.t xview" -orient horizontal
      
      set code "SELECT [join $columns ","] FROM $table"
      
      if {$param != ""} {
        append code " WHERE $param"
      }
      if {[catch {set results [ts eval $code]} err]} {
        pack [text $w.fdown.text] -side top -anchor ne -fill both
        $w.fdown.text insert end "Please ensure that a table and at least 1 field have been selected."
        return
      }
      
      tablelist::tablelist $w.fdown.t -columns [join $colnames " "] \
        -stretch all -background white -yscrollcommand "$w.fdown.s set" \
        -resizablecolumns 1 -selecttype cell -showeditcursor 0 \
        -showseparators 1 -xscrollcommand "$w.fdown.hs set"
      grid $w.fdown.t -row 0 -column 0 -sticky nsew
      grid $w.fdown.s -row 0 -column 1 -sticky nsew
      grid $w.fdown.hs -row 1 -column 0 -sticky nsew
      
      grid columnconfigure $w.fdown 0 -weight 1
      grid rowconfigure $w.fdown 0 -weight 1
      
      foreach $columns $results {
        set vars [lmap x $columns {set $x}]
        $w.fdown.t insert end $vars
      }
      
    }
    return
  }
  
  proc update_tableview {w stat} {
    set n [winfo parent $w]
    set ws [winfo children $n]
    set table [$n.tablecbox get]
    foreach w $ws {
      if {[regexp -- {field} $w] && $stat} {
        destroy $w
      }
    }
    set ws [winfo children $n]
    set fields [lsearch -all -regexp -nocase -inline $ws {fieldlab\d+}]
    if {$fields == {}} {
      set num 1
    } else {
      set fields [lmap m $fields {regexp -inline -- {\d+} $m}]
      set num [lindex [lsort -integer $fields] end]
      if {[$n.fieldscbox$num get] == "" || $num == 10} {return}
      incr num
    }
    label $n.fieldlab$num -text "Field $num:"
    grid $n.fieldlab$num -row $num -column 0 -pady 5 -padx 5
    
    set cols {}
    ts eval "SELECT * FROM $table" values {lappend cols $values(*); break}
    ttk::combobox $n.fieldscbox$num -values [list * {*}[lindex $cols 0]]
    grid $n.fieldscbox$num -row $num -column 1
    
    label $n.fieldlcond$num -text "where"
    grid $n.fieldlcond$num -row $num -column 2 -pady 5 -padx 5
    ttk::combobox $n.fieldccond$num -values {= > >= < <= LIKE}
    grid $n.fieldccond$num -row $num -column 3 -pady 5 -padx 5
    entry $n.fieldpcond$num
    grid $n.fieldpcond$num -row $num -column 4 -pady 5 -padx 5
    
    if {$num > 1} {
      set prev [expr {$num-1}]
      ttk::combobox $n.fieldcomp$prev -values {AND OR}
      $n.fieldcomp$prev set "AND"
      grid $n.fieldcomp$prev -row $prev -column 5 -pady 5 -padx 5
    }
    
    bind $n.fieldscbox$num <<ComboboxSelected>> {update_tableview %W 0}
  }
  
  set columns {}
  proc export_results {w} {
    upvar columns columns
    if {![winfo exists $w.fdown.t]} {
      tk_messageBox -icon error -title Error -message "No query has been run yet!"
      return
    }
    
    set types {{"Text files"   .txt}}
    set files [glob -nocomplain Query*.txt]
    if {[llength $files] == 0} {
      set number 1
    } else {
      regexp -- {Query(\d+)\.txt} [lindex $files end] - number
      incr number
    }
    set file [tk_getSaveFile -filetypes $types -parent $w \
      -initialfile "Query$number.txt" -initialdir [pwd] \
      -defaultextension .txt]
    if {$file == ""} {return}
    set f [open $file w]
    puts $f [join $columns \t]
    for {set i 0} {$i < [$w.fdown.t size]} {incr i} {
      set results [lindex [$w.fdown.t rowconfigure $i -text] 4]
      puts $f [join $results \t]
    }
    close $f
    exec {*}[auto_execok start] "Excel.exe" $file
    return
  }
}

new_row .fdown.tab ts
ts_load now
test_alarm

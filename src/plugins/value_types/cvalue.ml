(* Modified by TrustInSoft *)

(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2007-2015                                               *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Abstract_interp
open Locations
open Cil_types

module CardinalEstimate = struct
  (* We store the estimation as the log10 of the actual number. This is
     necessary because the number of states gets huge.
     None denotes a cardinal of 0. *)
  type t = float option

  let zero = None
  let one = Some 0.0
  let of_integer x = Some(Pervasives.log10 (Integer.to_float x))
  let infinite = Some(infinity)
  let mul a b = match (a,b) with
    | None, _ | _, None -> None
    | Some(a), Some(b) -> Some(a +. b);;
  let power a b = match a with
    | None -> None
    | a when Integer.is_one b -> a
    | Some(a) -> Some( a *. (Integer.to_float b))

  let pretty fmt a = match a with
    | None -> Format.fprintf fmt "0"
    | Some(a) ->
      let value = 10.0 ** a in
      if value < 10000.0
      then Format.fprintf fmt "%.0f" value
      else if (classify_float value) = FP_infinite
      then Format.fprintf fmt "10^%.2f" a
      else Format.fprintf fmt "10^%.2f (%.3g)" a value

  let pretty_long_log10 fmt a = match a with
    | None -> Format.fprintf fmt "-inf"
    | Some(a) -> Format.fprintf fmt "%.0f" a

end


module V = struct

  include Location_Bytes

  exception Not_based_on_null

  let project_ival m =
    try
      let k, v = find_lonely_key m in
      if not (Base.is_null k)
      then raise Not_based_on_null
      else v
    with Not_found -> raise Not_based_on_null

  let project_ival_bottom m =
    if is_bottom m then Ival.bottom else project_ival m

  let is_imprecise v =
    match v with
      | Top _ -> true
      | _ -> false

  let is_topint v = equal top_int v 

  let is_bottom v = equal bottom v

  let is_isotropic v =
    match v with
      | Top _ -> true
      | Map _ -> is_topint v || is_bottom v || is_zero v

  let contains_zero loc =
    try
      let is_valid_offset base offset =
        match base with
          Base.Null ->
            if Ival.contains_zero offset then raise Base.Not_valid_offset
        | _ ->
            let bits_offset = Ival.scale (Bit_utils.sizeofchar()) offset in
            Base.is_valid_offset ~for_writing:false Int.zero base bits_offset
      in
      match loc with
      | Location_Bytes.Top _ -> true
      | Location_Bytes.Map m ->
          Location_Bytes.M.iter is_valid_offset m;
          false
    with
    | Base.Not_valid_offset -> true

  let contains_non_zero v =
    not ((equal v bottom) || (is_zero v))

  let of_char c = inject_ival (Ival.of_int (Char.code c))

  let of_int64 i = inject_ival (Ival.of_int64 i)

  let inject_int (v:Int.t) =
    inject_ival (Ival.inject_singleton v)

  let interp_boolean ~contains_zero ~contains_non_zero =
    match contains_zero, contains_non_zero with
    | true, true -> zero_or_one
    | true, false -> singleton_zero
    | false, true -> singleton_one
    | false, false -> bottom

  (* Pretty-printing *)

  (* Pretty the partial address [b(base)+i(offsets)] in a basic way,
     by printing [i] as an [Ival.t] *)
  let pretty_base_offsets_default fmt b i =
    if Ival.equal Ival.zero i then
      Format.fprintf fmt "@[%a@]" Base.pretty_addr b
    else
      Format.fprintf fmt "@[%a +@ %a@]" Base.pretty_addr b Ival.pretty i

  (* Pretty the partial address [b(base)+i(offsets)], supposing it has type
     [typ]. Whenever possible, we print real addresses instead of bytes
     offsets. *)
  let pretty_base_offsets_typ typ fmt b i =
    let typ_match = match Extlib.opt_map Cil.unrollType typ with
      | Some (TPtr (typ_pointed, _)) ->
        if Cil.isVoidType typ_pointed then None else Some typ_pointed
      | _ -> None
    in
    try
      let v_base = Base.to_varinfo b in
      let typ_base = v_base.vtype in
      (* Manually pretty a cast to [typ_pointed *] *)
      let pretty_cast fmt ok =
        if not ok then
          match typ with
          | None -> Format.fprintf fmt "(? *)"
          | Some typ -> Format.fprintf fmt "(%a)" Printer.pp_typ typ
      in
      (* Find an offset in [typ_base] at byte [ioffset] such that the offset
         is of type [typ_match]. If no such offset exists, find an offset
         that does not have the proper type. *)
      let conv_offset ioffset =
        let ioffsbits = Int.mul ioffset (Bit_utils.sizeofchar ()) in
        let find_match om =
          fst (Bit_utils.find_offset typ_base ~offset:ioffsbits om)
        in
        try
          match typ_match with
          | None -> raise Bit_utils.NoMatchingOffset
          | Some typ -> find_match Bit_utils.(MatchType typ), true
        with Bit_utils.NoMatchingOffset ->
          (* Backup solution: no type to match, or no offset with the proper
             type. Find a matching offset with potentially the wrong type *)
          find_match Bit_utils.MatchFirst, false
      in
      match i with
      | Ival.Set [|o|] ->
        (* One single offset. Use a short notation, and an even shorter one
           if we represent [&b] *)
        let o, ok = conv_offset o in
        if o = NoOffset then
          Format.fprintf fmt "@[%a%a@]" pretty_cast ok Base.pretty_addr b
        else
          Format.fprintf fmt "@[%a%a%a@]"
            pretty_cast ok Base.pretty_addr b Printer.pp_offset o
      | Ival.Set a -> (* Multiple offsets. We use a set notation *)
        (* Catch NoOffset, which we would be printed as '{, [1], [2]}. Instead,
           we find a slightly deeper offset. We should never be in a different
           case from array/comp, as the other types cannot have multiple
           offsets. *)
        let conv_offset' o =
          let o, ok = conv_offset o in
          if o = NoOffset then
            let o' = match Cil.unrollType typ_base with
              | TArray _ -> Index (Cil.(zero builtinLoc), NoOffset)
              | TComp (ci, _, _) -> Field (List.hd ci.cfields, NoOffset)
              | _ -> raise Bit_utils.NoMatchingOffset
            in o', ok
          else o, ok
        in
        let arr_off, ok =
          Array.fold_right
            (fun o (l, ok)-> let o', ok' = conv_offset' o in o' :: l, ok && ok')
            a ([], true)
        in
        Format.fprintf fmt "@[%a%a{%a}@]"
          pretty_cast ok
          Base.pretty_addr b
          (Pretty_utils.pp_iter
             ~sep:",@ " List.iter Printer.pp_offset) arr_off
      | Ival.Top _ ->
        (* Too many offsets. Currently, we use the basic notation. *)
        pretty_base_offsets_default fmt b i
      | Ival.Float _ -> assert false
    with
    (* Strange looking base, or no offset found. Use default printing *)
    | Base.Not_a_C_variable | Bit_utils.NoMatchingOffset ->
      pretty_base_offsets_default fmt b i

  (* Pretty-print a map of bases, using auxiliary function pp_base *)
  let pretty_pointers fmt pp_base m =
    Pretty_utils.pp_iter
      ~pre:"@[<hov 3>{{ " ~suf:" }}@]" ~sep:" ;@ "
      (fun pp map -> M.iter (fun k v -> pp (k, v)) map)
      (fun fmt (k, v) -> pp_base fmt k v)
      fmt m

  let pretty_typ typ fmt v =
    let pretty_org fmt org =
      if not (Origin.is_top org) then
        Format.fprintf fmt "@ @[(origin: %a)@]" Origin.pretty org
    in
    match v with
    | Top (Base.SetLattice.Top, a) ->
      Format.fprintf fmt "{{ ANYTHING%a }}"
        pretty_org a
    | Top (Base.SetLattice.Set t, a) ->
      let t = Base.SetLattice.(inject (O.remove Base.null t)) in
      Format.fprintf fmt "{{ garbled mix of &%a%a }}"
        Base.SetLattice.pretty t pretty_org a
    | Map m ->
      try
        Ival.pretty fmt (project_ival v)
      with
      | Not_based_on_null ->
        try
          pretty_pointers fmt (pretty_base_offsets_typ typ) m
        with Cil.SizeOfError _ ->
          (* Standard printing as a set of (base+ival) *)
          pretty_pointers fmt pretty_base_offsets_default m

  let pretty fmt v = match v with
    | Top _ -> pretty_typ None fmt v
    | Map m ->
      try
        Ival.pretty fmt (project_ival v)
      with
      | Not_based_on_null -> pretty_pointers fmt pretty_base_offsets_default m


  (** Comparisons *)

  let compare_bound ival_compare_bound l1 l2 =
    if l1 == l2 then 0
    else if is_bottom l2 then -1
    else if is_bottom l1 then 1
    else try
	let f1 = project_ival l1 in
	let f2 = project_ival l2 in
	ival_compare_bound f1 f2
    with Not_based_on_null -> assert false

  let compare_min_float = compare_bound Ival.compare_min_float
  let compare_max_float = compare_bound Ival.compare_max_float
  let compare_min_int = compare_bound Ival.compare_min_int
  let compare_max_int = compare_bound Ival.compare_max_int

  let backward_rel_int_left op l r =
    let open Abstract_interp.Comp in
    match l with
      | Top _  -> l
      | Map m1 ->
          try
            let k,v2 = find_lonely_key r in
            let v1 = find_or_bottom k m1 in
            let v1' = Ival.backward_comp_int_left op v1 v2 in
            let r = add k v1' l in
            if (not (Base.equal k Base.null)) && (op = Ge || op = Gt)
            then diff_if_one r singleton_zero
            else r
          with Not_found -> l

  (* More agressive reduction by relational pointer operators. This version
     assumes that \pointer_comparable alarms have been emitted, and that
     we want to reduce by them. For example, &a < &b reduces to bottom,
     which might be problematic if &a and &b have been cast to uintptr_t *)
  let _backward_rel_int_left op l r =
    let debug = false in
    (* Pointwise operation on the base [b], bound to [il] in [l] *)
    let aux_base b il acc =
      let ir = find b r in
      if Ival.is_bottom ir then acc
      else
        let il' = Ival.backward_comp_int_left op il ir in
        if not (Ival.is_bottom il')
        then add b il' acc
        else acc
    in
    if true then
      fold_topset_ok aux_base l bottom
    else (* Complicated version that accepts comparisons 0 < &p *)
      try
        let il, pl = split Base.null l in
        let ir, pr = split Base.null r in
        let zl = Ival.contains_zero il in
        let zr = Ival.contains_zero ir in
        let il' = Ival.backward_comp_int_left op il ir in
        let pl' = fold_topset_ok aux_base pl bottom in
        let open Abstract_interp.Comp in
        (* i1' and p1' are pointwise application of the comparison operator,
           and will be in the result in all cases. *)
        if debug then Kernel.result "%a %a %a %a %a -> %a %a"
          Ival.pretty il pretty pl pretty_comp op Ival.pretty ir pretty pr
          Ival.pretty il' pretty pl';
        match op, zl, zr with
        | (Le | Lt), false, _ (*  il       + pl <~ (ir + ?0) + pr *)
        | (Ge | Gt), _, false (* (il + ?0) + pl >~  ir       + pr *) ->
          add Base.null il' pl'
        | (Le | Lt), true, _ -> (* 0 + il + pl <~ ir + pr *)
          if is_bottom pr then
            add Base.null il' pl'
          else
            (* also keep the NULL pointer, that compares less than pr *)
            add Base.null (Ival.join Ival.zero il') pl'
        | (Ge | Gt), _, true -> (* il + pl >~ 0 + pr *)
          (* keep all of pl, as they are all greater than 0; this includes pl'*)
          add Base.null il' pl
        | _ -> assert false
      with Error_Top -> l

  let backward_comp_int_left op l r =
    let open Abstract_interp.Comp in
    match op with
    | Ne -> diff_if_one l r
    | Eq -> narrow l r
    | Le | Lt | Ge | Gt -> backward_rel_int_left op l r

  let backward_comp_float_left op allmodes fkind l r =
    try
      let vl = project_ival l in
      let vr = project_ival r in
      inject_ival (Ival.backward_comp_float_left op allmodes fkind vl vr)
    with Not_based_on_null -> l

  let inject_comp_result = function
    | Comp.True -> singleton_one
    | Comp.False -> singleton_zero
    | Comp.Unknown -> zero_or_one

  let forward_rel_int ~signed op e1 e2 =
    let open Abstract_interp.Comp in
    try
      let k1,v1 = find_lonely_key e1 in
      let k2,v2 = find_lonely_key e2 in
      if Base.equal k1 k2 then
        Ival.forward_comp_int op v1 v2
      else begin
        if signed then
          Unknown
        else begin
          (* k1 -> v1, k2 -> v2, k1 <> k2 *)
          let e1_zero = equal e1 singleton_zero in
          let e2_zero = equal e2 singleton_zero in
          if (e1_zero && (op = Le || op = Lt))
          || (e2_zero && (op = Ge || op = Gt))
          then True (* if e1/e2 is NULL, then e2/e1 is a pointer *)
          else
            if (e2_zero && (op = Le || op = Lt))
            || (e1_zero && (op = Ge || op = Gt))
            then False
            else Unknown
        end
      end
    with Not_found -> Comp.Unknown

  let forward_eq_int e1 e2 =
    if (equal e1 e2) && (cardinal_zero_or_one e1)
    then Comp.True
    else if intersects e1 e2
    then Comp.Unknown
    else Comp.False

  let forward_comp_int ~signed op v1 v2 =
    let open Abstract_interp.Comp in
    match op with
      | Eq -> forward_eq_int v1 v2
      | Ne -> inv_result (forward_eq_int v1 v2)
      | Le | Ge | Lt | Gt -> forward_rel_int ~signed op v1 v2


  (** Casts *)

  let cast_float ~rounding_mode v =
    try
      let i = project_ival v in
      let b, i = Ival.force_float FFloat i in
      let b', i = Ival.cast_float ~rounding_mode i in
      false, b || b', inject_ival i
    with
      Not_based_on_null ->
	if is_bottom v
	then false, false, bottom
	else true, true, topify_arith_origin v

  let cast_double v =
    try
      let i = project_ival v in
      let b, i = Ival.force_float FDouble i in
      let b', i = Ival.cast_double i in
      false, b || b', inject_ival i
    with
      Not_based_on_null ->
	if is_bottom v
	then false, false, bottom
	else true, true, topify_arith_origin v

  let cast ~size ~signed v =
    let integer_part, pointer_part = split Base.null v in
    let integer_part' = Ival.cast ~size ~signed ~value:integer_part in
    let pointer_part', ok = 
      if Int.ge size (Int.of_int (Bit_utils.sizeofpointer ())) ||
        is_bottom pointer_part || is_imprecise pointer_part
      then pointer_part, true
      else topify_arith_origin pointer_part, false      
    in
    if ok && integer_part' == integer_part then
      v, true
    else
      (join (inject_ival integer_part') pointer_part'), ok

 let cast_float_to_int ~signed ~size v =
   try
     let v1 = project_ival v in
     let alarm_use_as_float, alarm_overflow, r =
       Ival.cast_float_to_int ~signed ~size v1
     in
     false, alarm_use_as_float, alarm_overflow, inject_ival r
   with Not_based_on_null ->
     if is_bottom v then
       false, false, (false, false), v
     else
       (not (is_bottom v)), true, (true, true), topify_arith_origin v

 let cast_float_to_int_inverse ~single_precision i =
   try
     let v1 = project_ival i in
     let r = Ival.cast_float_to_int_inverse ~single_precision v1
     in
     inject_ival r
   with Not_based_on_null -> assert false

 let cast_int_to_float rounding_mode v =
   try
     let i = project_ival v in
     let ok, r = Ival.cast_int_to_float rounding_mode i in
     inject_ival r, ok
   with Not_based_on_null -> v, false


  (** Binary functions *)

  let import_function ~topify f e1 e2 =
    try
      let v1 = project_ival e1 in
      let v2 = project_ival e2 in
      inject_ival (f v1 v2)
    with Not_based_on_null  ->
      if is_bottom e1 || is_bottom e2 
      then bottom
      else begin
	  join
            (topify_with_origin_kind topify e1)
            (topify_with_origin_kind topify e2)
	end

  let arithmetic_function = import_function ~topify:Origin.K_Arith

  (* Compute the pointwise difference between two Locations_Bytes.t. *)
  let sub_untyped_pointwise v1 v2 =
    let open Locations in
    match v1, v2 with
    | Top _, Top _
    | Top (Base.SetLattice.Top, _), Map _
    | Map _, Top (Base.SetLattice.Top, _) ->
      Ival.top, true
    | Top (Base.SetLattice.Set s, _), Map m
    | Map m, Location_Bytes.Top (Base.SetLattice.Set s, _) ->
      (* Differences between pointers containing garbled mixes must always
       result in an alarm, as garbled mix at least contain a pointer and NULL *)
      let s' = Base.SetLattice.O.add Base.null s in
      if Base.SetLattice.O.(intersects s' (from_shape (M.shape m))) then
        Ival.top, true
      else
        Ival.bottom, true
    | Map m1, Map m2 ->
      (* Substract pointwise for all the bases that are present in both m1
         and m2. Could be written more efficiently with a recursive simultaneous
         descent, but not such iterator currently exists. *)
      let aux b offsm1 (acc_offs, cardm1) =
        let acc_offs =
          try
            let offsm2 = M.find b m2 in
            Ival.join (Ival.sub_int offsm1 offsm2) acc_offs
          with Not_found -> acc_offs
        in
        acc_offs, succ cardm1
      in
      let offsets, cardm1 = M.fold aux m1 (Ival.bottom, 0) in
      (* If cardm1 > 1 or cardm2 > 1 or m1 and m2 are disjoint, we must emit
         an alarm *)
      let warn = cardm1 > 1 || Ival.is_bottom offsets ||
        (try ignore (find_lonely_key v2); false with Not_found -> true)
      in
      offsets, warn

  let topify_arith_origin_2 v1 v2 =
    join (topify_arith_origin v1) (topify_arith_origin v2)

  (* compute [e1+factor*e2] using C semantic for +, i.e.
     [ptr+v] is [add_untyped sizeof_in_octets( *ptr) ptr v]. This function
     handles simultaneously PlusA, MinusA, PlusPI, MinusPI and sometimes
     MinusPP, by setting [factor] accordingly. This is more precise than
     having multiple functions, as computations such as
     [(int)&t[1] - (int)&t[2]] would not be treated precisely otherwise. *)
  let add_untyped factor e1 e2 =
    try
      if Int_Base.equal factor (Int_Base.minus_one)
      then
        (* Either e1 and e2 have the same base, and it's a subtraction
           of pointers, or e2 is really an integer *)
        let b1, o1 = Location_Bytes.find_lonely_key e1 in
        let b2, o2 = Location_Bytes.find_lonely_key e2 in
        if Base.compare b1 b2 <> 0 then raise Not_found;
        inject_ival (Ival.sub_int o1 o2)
      else begin
        if not (Int_Base.equal factor (Int_Base.one)) then
          raise Not_found (* cannot multiply a pointer *);
        try
          Location_Bytes.shift (project_ival_bottom e2) e1
        with Not_based_on_null  ->
          try (* On the off chance that someone writes [i+(int)&p]... *)
            Location_Bytes.shift (project_ival_bottom e1) e2
          with Not_based_on_null ->
            topify_arith_origin_2 e1 e2
      end
    with Not_found ->
      (* we end up here if the only way left to make this
         addition is to convert e2 to an integer *)
      try
        let right = Ival.scale_int_base factor (project_ival_bottom e2)
        in Location_Bytes.shift right e1
      with Not_based_on_null  -> (* from [project_ival] *)
        topify_arith_origin_2 e1 e2

  (* Under-approximating variant of add_untyped. Takes two
     under-approximation, and returns an under-approximation.*)
  let add_untyped_under factor e1 e2 =
    if Int_Base.equal factor (Int_Base.minus_one)
    then
      (* Note: we could do a "link" for each pair of matching bases in
	 e1 and e2, so this is an underapproximation in the most
	 common case. *)
      try
	let b1, o1 = Location_Bytes.find_lonely_key e1 in
	let b2, o2 = Location_Bytes.find_lonely_key e2 in
	if Base.compare b1 b2 <> 0 then bottom
	else inject_ival (Ival.sub_int_under o1 o2)
      with Not_found -> bottom
    else if Int_Base.equal factor Int_Base.one
    then
      try Location_Bytes.shift_under (project_ival_bottom e2) e1
      with Not_based_on_null -> bottom
    else
      try
	let right = Ival.scale_int_base factor (project_ival_bottom e2) in
	Location_Bytes.shift_under right e1
      with Not_based_on_null -> bottom
  ;;

  let div e1 e2 =
    arithmetic_function Ival.div e1 e2

  let c_rem ~signed e1 e2 =
    let alignment = Int.of_int (Kernel.AddressAlignment.get()) in
    try
      let i2 = project_ival e2 in
      match i2 with
      | Ival.Set a when not signed ->
        Array.iter
          (fun i ->
            if Int.is_zero i || not (Int.is_zero (Int.rem alignment i))
            then raise Not_based_on_null)
          a;
        ( match e1 with
        | Map m ->
          let rem_i _base i1 acc =
            let ri = Ival.c_rem i1 i2 in
            Ival.join acc ri
          in
          inject_ival (M.fold rem_i m Ival.bottom)
        | Top _ -> e1)
      | _ -> raise Not_based_on_null
    with
      Not_based_on_null ->
        arithmetic_function Ival.c_rem e1 e2

  let mul e1 e2 =
    arithmetic_function Ival.mul e1 e2

  let shift_left e1 e2 =
    arithmetic_function Ival.shift_left e1 e2

  let bitwise_xor v1 v2 =
    if equal v1 v2 && cardinal_zero_or_one v1
    then singleton_zero
    else
      let handle_ival_ptr i p =
        match p with
        | Map m ->
          ( match Ival.min_and_max i with
          | Some l, Some u -> 
            let alignment = Int.of_int (Kernel.AddressAlignment.get()) in
            let is_small_ptrmask = Int.le Int.zero l && Int.lt u alignment
            in
            if is_small_ptrmask
            then
              let xor_i base i2 acc =
                let ni = Ival.bitwise_xor i i2 in
                join acc (inject base ni)
              in
              M.fold xor_i m bottom
            else
              topify_arith_origin p
          | _, _ -> topify_arith_origin p)
        | Top _ -> p
      in
      try
        let i1 = project_ival v1 in
        try
          let i2 = project_ival v2 in
          inject_ival (Ival.bitwise_xor i1 i2)
        with Not_based_on_null -> handle_ival_ptr i1 v2
      with Not_based_on_null -> 
        try
          let i2 = project_ival v2 in
          handle_ival_ptr i2 v1
        with Not_based_on_null -> 
          topify_arith_origin_2 v1 v2

  let bitwise_or_with_topify ~topify v1 v2 =
    if equal v1 v2 && cardinal_zero_or_one v1
    then v1
    else 
      let handle_ival_ptr i p =
        match p with
        | Map m ->
          ( match Ival.min_and_max i with
          | Some l, Some u -> 
            let alignment = Int.of_int (Kernel.AddressAlignment.get()) in
            let is_small_ptrmask = Int.le Int.zero l && Int.lt u alignment
            in
            if is_small_ptrmask
            then
              let or_i base i2 acc =
                let ni = Ival.bitwise_or i i2 in
                join acc (inject base ni)
              in
              M.fold or_i m bottom
            else
              topify_with_origin_kind topify p
          | _, _ -> topify_with_origin_kind topify p)
        | Top _ -> p
      in
      try
        let i1 = project_ival v1 in
        try
          let i2 = project_ival v2 in
          inject_ival (Ival.bitwise_or i1 i2)
        with Not_based_on_null -> handle_ival_ptr i1 v2
      with Not_based_on_null -> 
        try
          let i2 = project_ival v2 in
          handle_ival_ptr i2 v1
        with Not_based_on_null -> 
          join 
            (topify_with_origin_kind topify v1)
            (topify_with_origin_kind topify v2)

  let bitwise_or = bitwise_or_with_topify ~topify:Origin.K_Arith

  let bitwise_and ~signed ~size v1 v2 =
    if equal v1 v2 && cardinal_zero_or_one v1
    then v1
    else 
      let and_ival i1 i2 = Ival.bitwise_and ~size ~signed i1 i2 in
      let handle_ival_ptr i p =
        match p with
        | Map m ->
          let max_ptr = Int.pred
            (Int.two_power_of_int 
               (((Cil.bitsSizeOf Cil.charType)) * 
                   Cil.(theMachine.theMachine.sizeof_ptr)))
          in
          let alignment = Int.of_int (Kernel.AddressAlignment.get()) in
          ( match Ival.min_and_max i with
          | Some l, Some u ->
            let is_complement =
              Int.lt (Int.sub max_ptr alignment) l && Int.le u max_ptr
            in
            if is_complement
            then 
              let and_complement base i2 acc =
                let ni = Ival.bitwise_and ~size ~signed i i2 in
                join acc (inject base ni)
              in
              M.fold and_complement m bottom
            else
              let is_small_ptrmask = Int.le Int.zero l && Int.lt u alignment
              in
              if is_small_ptrmask
              then
                let and_i _base i2 acc =
                  Ival.join (and_ival i2 i) acc
                in
                let result = M.fold and_i m Ival.bottom in
                inject_ival result
              else
                topify_arith_origin p
          | _, _ -> topify_arith_origin p)
        | Top _ -> p
      in
      try
        let i1 = project_ival v1 in
        try
          let i2 = project_ival v2 in
          inject_ival (and_ival i1 i2)
        with Not_based_on_null -> handle_ival_ptr i1 v2
      with Not_based_on_null -> 
        try
          let i2 = project_ival v2 in
          handle_ival_ptr i2 v1
        with Not_based_on_null -> 
          topify_arith_origin_2 v1 v2




  let shift_right e1 e2 =
    arithmetic_function Ival.shift_right e1 e2

  let extract_bits ~topify ~start ~stop ~size v =
    try
      let i = project_ival_bottom v in
      false, inject_ival (Ival.extract_bits ~start ~stop ~size i)
    with
      | Not_based_on_null ->
          if is_imprecise v
          then false, v
          else true, topify_with_origin_kind topify v

  (* Computes [e * 2^factor]. Auxiliary function for foo_endian_merge_bits *)
  let shift_left_by_integer ~topify factor e =
    try
      let i = project_ival_bottom e in
      inject_ival (Ival.scale (Int.two_power factor) i)
    with
    | Not_based_on_null  -> topify_with_origin_kind topify e
    | Integer.Too_big -> top_int

  let big_endian_merge_bits ~topify ~conflate_bottom ~total_length ~length ~value ~offset acc =
    if is_bottom acc || is_bottom value
    then begin
        if conflate_bottom
        then
          bottom
        else
          join
            (topify_with_origin_kind topify acc)
            (topify_with_origin_kind topify value)
      end
    else
      let total_length_i = Int.of_int total_length in
      let factor = Int.sub (Int.sub total_length_i offset) length in
      let value' = shift_left_by_integer ~topify factor value in
      let result = bitwise_or_with_topify ~topify value' acc in
(*    Format.printf "big_endian_merge_bits : total_length:%d length:%a value:%a offset:%a acc:%a GOT:%a@."
      total_length
      Int.pretty length
      pretty value
      Int.pretty offset
      pretty acc
      pretty result; *)
    result

  let little_endian_merge_bits ~topify ~conflate_bottom ~value ~offset acc =
    if is_bottom acc || is_bottom value
    then begin
        if conflate_bottom
        then
          bottom
        else
          join
            (topify_with_origin_kind topify acc)
            (topify_with_origin_kind topify value)
      end
    else
      let value' = shift_left_by_integer ~topify offset value in
      let result = bitwise_or_with_topify ~topify value' acc in
    (*Format.printf "le merge_bits : total_length:%d value:%a offset:%a acc:%a GOT:%a@."
      total_length pretty value Int.pretty offset pretty acc pretty result;*)
    result

  (* neutral value for foo_endian_merge_bits *)
  let merge_neutral_element = singleton_zero

  let all_values ~size v =
    if Int.(equal size zero) then true
    else
      try
        let i = project_ival v in
        Ival.all_values ~size i
    with Not_based_on_null -> 
        false

  let anisotropic_cast ~size v =
    if all_values ~size v then top_int else v

  let create_all_values ~signed ~size =
    inject_ival (Ival.create_all_values ~signed ~size)

  let cardinal_estimate lb size = match lb with
    | Top _ -> Int.two_power size (* TODO: this could be very slow when [size]
                                     is big *)
    | Map m ->
      M.fold (fun _ v card ->
        Int.add card (Ival.cardinal_estimate v size)
      ) m Int.zero

  (** Check if a pointer is precise. *)
  let is_ptr_precise (ptr : t) : bool =
    (* [find_lonely_key] raises [Not_found] if there is more than one base. *)
    try
      let _ptr_base, _ptr_offsets = find_lonely_key ptr in true
    with Not_found -> false

  (** Check if a pointer is valid for comparison. *)
  let is_ptr_valid (ptr : t) : bool =
    (* First convert the pointer cvalue to a location. *)
    let location =
      (* Location size for the purpose of checking validity: one byte. *)
      let loc_size = Bit_utils.sizeofchar () in
      Locations.make_loc
        (Locations.loc_bytes_to_loc_bits ptr)
        (Int_Base.inject loc_size)
    in
    (* Now check the location's validity. *)
    Locations.is_valid ~for_writing:false location
  
  let precise_ptr_compare binop ptr1 ptr2 : Abstract_interp.Comp.result =
    
    let open Abstract_interp.Comp in
    
    let offsets_compare binop offsets1 offsets2 : result =
      let is_an_offset = function
        | Ival.Set   _ -> true
        | Ival.Top   _ -> true
        | Ival.Float _ -> false
      in
      assert (is_an_offset offsets1 && is_an_offset offsets2);
      Ival.forward_comp_int binop offsets1 offsets2
    in
        
    let bases_compare binop base1 base2 : bool =
      let comp_result = Base.compare base1 base2 in
      (* [comp_result < 0  <==> base1 < base2]
       * [comp_result = 0  <==> base1 = base2]
       * [comp_result > 0  <==> base1 > base2] 
       * etc... *)
      let predicate = to_predicate binop in
      predicate comp_result 0
    in
    
    let base1, offsets1 = try find_lonely_key ptr1 with Not_found -> assert false
    and base2, offsets2 = try find_lonely_key ptr2 with Not_found -> assert false
    in
    (* First check if the bases are equal. *)
    if bases_compare Eq base1 base2
    then
      (* The bases are equal: we should compare their offsets. *)
      offsets_compare binop offsets1 offsets2
    else
      (* The bases are not equal: comparing them directly will be enough. *)
      if bases_compare binop base1 base2
      then True
      else False

  let ptr_compare binop ptr1 ptr2 =
    let are_ptrs_precise = (is_ptr_precise ptr1) && (is_ptr_precise ptr2)
    and are_ptrs_valid   = (is_ptr_valid   ptr1) && (is_ptr_valid   ptr2)
    in
    (* Possible comparison results: *)
    let result_true         = true,  singleton_one
    and result_false        = true,  singleton_zero
    and result_bottom       = false, bottom
    and result_undetermined = false, zero_or_one
    in
    match are_ptrs_precise, are_ptrs_valid with
    (* Both pointers are precise and valid, thus we can compare them. *)
    | true, true ->
        begin
          let ptr_comp_result = precise_ptr_compare binop ptr1 ptr2 in
          let open Abstract_interp.Comp in
          match ptr_comp_result with
          | True    -> result_true
          | False   -> result_false
          | Unknown -> result_undetermined
        end
    (* Both pointers are precise, but at least one is invalid. *)
    (* TODO: Pointer validity could be handled better, we could compare only
             the valid bases, if there are any. *)
    | true, false -> result_bottom
    (* At least one pointer is imprecise. *)
    | false, _    -> result_undetermined

end

module V_Or_Uninitialized = struct

  (* Note: there is a "cartesian product" of the escape and init flags
     in the constructors, instead of having a tuple or two sum types,
     for performance reasons: this avoids an indirection. *)
  type t =
    | C_uninit_esc of V.t
    | C_uninit_noesc of V.t
    | C_init_esc of V.t
    | C_init_noesc of V.t

  let make ~initialized ~escaping v =
    match initialized, escaping with
      | true, false  -> C_init_noesc v
      | true, true   -> C_init_esc v
      | false, false -> C_uninit_noesc v
      | false, true  -> C_uninit_esc v

  let mask_init = 2
  let mask_noesc = 1

  external get_flags : t -> int = "caml_obj_tag" "noalloc"

  let is_initialized v = (get_flags v land mask_init) <> 0
  let is_noesc v = (get_flags v land mask_noesc) <> 0

  let get_v = function 
    | C_uninit_esc  v
    | C_uninit_noesc v
    | C_init_esc v
    | C_init_noesc v -> v

  let is_indeterminate = function
    | C_init_noesc _ -> false
    | _ -> true

  let create : int -> V.t -> t = fun flags v ->
    match flags with
    | 0 -> C_uninit_esc v
    | 1 -> C_uninit_noesc v
    | 2 -> C_init_esc v
    | 3 -> C_init_noesc v
    | _ -> assert false

(* let (==>) = (fun x y -> (not x) || y) *)

  type size_widen_hint = V.size_widen_hint
  type generic_widen_hint = V.generic_widen_hint
  type widen_hint = V.widen_hint
  let widen wh t1 t2 =
    create (get_flags t2) (V.widen wh (get_v t1) (get_v t2))

  let equal t1 t2 =
    (get_flags t1) = (get_flags t2) &&
    V.equal (get_v t1) (get_v t2)

  let join t1 t2 =
    create
      ((get_flags t1) land (get_flags t2))
      (V.join (get_v t1) (get_v t2))

  let narrow t1 t2 =
    create
      ((get_flags t1) lor (get_flags t2))
      (V.narrow (get_v t1) (get_v t2))

  let link t1 t2 =
    create
      ((get_flags t1) land (get_flags t2))
      (V.link (get_v t1) (get_v t2))

  let meet t1 t2 =
   create
      ((get_flags t1) lor (get_flags t2))
      (V.meet (get_v t1) (get_v t2))

  let map f v = create (get_flags v) (f (get_v v))

  let bottom = C_init_noesc V.bottom
  let top = C_uninit_esc V.top

  let is_bottom = equal bottom

  let uninitialized = C_uninit_noesc V.bottom
  let initialized v = C_init_noesc v

  let is_included t1 t2 =
(*    (t2.initialized ==> t1.initialized) &&
    (t2.no_escaping_adr ==> t1.no_escaping_adr) &&
      V.is_included t1.v t2.v
*)
    let flags1 = get_flags t1 in
    let flags2 = get_flags t2 in
    (lnot flags2) lor flags1 = -1 &&
        V.is_included (get_v t1) (get_v t2)

  let join_and_is_included t1 t2 =
    let t12 = join t1 t2 in (t12, equal t12 t2)

  let pretty_aux pp fmt t =
    let no_escaping_adr = is_noesc t in
    let initialized = is_initialized t in
    let v = get_v t in
    match V.(equal bottom v), initialized, no_escaping_adr with
      | false, false, false ->
        Format.fprintf fmt "%a or UNINITIALIZED or ESCAPINGADDR" pp v
      | true, false, false ->
        Format.pp_print_string fmt "UNINITIALIZED or ESCAPINGADDR"
      | false, false, true ->
        Format.fprintf fmt "%a or UNINITIALIZED" pp v
      | true, false, true ->
        Format.pp_print_string fmt "UNINITIALIZED"
      | false, true, false ->
        Format.fprintf fmt "%a or ESCAPINGADDR" pp v
      | true, true, false ->
        Format.pp_print_string fmt "ESCAPINGADDR"
      | false, true, true ->
        pp fmt v
      | true, true, true ->
        Format.pp_print_string fmt "BOTVALUE"

  let pretty fmt v = pretty_aux V.pretty fmt v
  let pretty_typ typ fmt v =
    pretty_aux (fun fmt v -> V.pretty_typ typ fmt v) fmt v

  let cardinal_zero_or_one t =
    match t with
      C_init_noesc v -> V.cardinal_zero_or_one v
    | C_init_esc v | C_uninit_noesc v -> V.is_bottom v
    | C_uninit_esc _ -> false

  let hash t = (get_flags t) * 4513 + (V.hash (get_v t))

  include
    (Datatype.Make
      (struct
        type uninitialized = t
        type t = uninitialized (* =     | C_uninit_esc of V.t
                       | C_uninit_noesc of V.t
                       | C_init_esc of V.t
                       | C_init_noesc of V.t *)
        let name = "Cvalue.V_Or_Uninitialized"
        let structural_descr =
	  let v = V.packed_descr in
           Structural_descr.t_sum [| [| v |]; [| v |]; [| v |]; [| v |] |]
        let reprs =
          List.fold_left
            (fun acc v ->
              List.fold_left
                (fun acc v ->
                  List.fold_left
                    (fun acc v -> C_uninit_noesc v :: acc)
                    (C_uninit_esc v :: acc)
                    V.reprs)
                (C_init_noesc v :: acc)
                V.reprs)
            (List.map (fun v -> C_init_esc v) V.reprs)
            V.reprs
        let hash = hash
        let equal = equal
        let compare = Datatype.undefined
        let copy = Datatype.undefined
        let rehash = Datatype.identity
        let pretty = pretty
        let internal_pretty_code = Datatype.undefined
        let varname = Datatype.undefined
        let mem_project = Datatype.never_any_project
       end)
     : Datatype.S with type t := t)

  module Top_Param = Base.SetLattice

  let is_isotropic t = V.is_isotropic (get_v t)

  let extract_bits ~topify ~start ~stop ~size t =
    let inform_extract_pointer_bits, v =
      V.extract_bits ~topify ~start ~stop ~size (get_v t)
    in
    inform_extract_pointer_bits,
    create (get_flags t) v

  let little_endian_merge_bits ~topify ~conflate_bottom ~value ~offset t =
    create
      ((get_flags t) land (get_flags value))
      (V.little_endian_merge_bits ~topify ~conflate_bottom
          ~value:(get_v value) ~offset
          (get_v t))

  let big_endian_merge_bits ~topify ~conflate_bottom ~total_length ~length ~value ~offset t =
    create
      ((get_flags t) land (get_flags value))
      (V.big_endian_merge_bits ~topify ~conflate_bottom
          ~total_length ~length
          ~value:(get_v value)
          ~offset
          (get_v t))

  let topify_with_origin o t =
    create
      (get_flags t)
      (V.topify_with_origin o (get_v t))

  let anisotropic_cast ~size t =
    create
      (get_flags t)
      (V.anisotropic_cast ~size (get_v t))

  let singleton_zero = C_init_noesc (V.singleton_zero)
  let merge_neutral_element = singleton_zero

  let unspecify_escaping_locals ~exact is_local t =
    let flags = get_flags t in
    let flags = flags land mask_init
      (* clear noesc flag *)
    in
    let v = get_v t in
    let locals, v' = V.remove_escaping_locals is_local v in
    let v = if exact then v' else V.join v v' in
    locals, create flags v

  let reduce_by_initializedness init v = match init, v with
    | true, C_uninit_esc v -> C_init_esc v
    | true, C_uninit_noesc v -> C_init_noesc v
    | true, (C_init_esc _ | C_init_noesc _) -> v
    | false, (C_init_esc _ | C_init_noesc _) -> bottom
    | false, C_uninit_noesc _ -> C_uninit_noesc V.bottom
    | false, C_uninit_esc _ -> C_uninit_esc V.bottom

  let reduce_by_danglingness spec v = match spec, v with
    | false, C_uninit_esc v -> C_uninit_noesc v
    | false, C_init_esc v -> C_init_noesc v
    | false, (C_uninit_noesc _ | C_init_noesc _) -> v
    | true, (C_uninit_noesc _ | C_init_noesc _) -> bottom
    | true, C_uninit_esc _ -> C_uninit_esc V.bottom
    | true, C_init_esc _ -> C_init_esc V.bottom

  let remove_indeterminateness = function
    | C_init_noesc _ as v -> v
    | (C_uninit_noesc v | C_uninit_esc v | C_init_esc v) -> C_init_noesc v

  let cardinal_estimate v size =
    let vcard v = V.cardinal_estimate v size in
    match v with
    | C_init_noesc(v) -> vcard v
    | C_uninit_noesc(v) | C_init_esc(v) -> Integer.add Integer.one (vcard v)
    | C_uninit_esc(v) -> Integer.add Integer.two (vcard v)
end

module V_Offsetmap = struct
  include Offsetmap.Make(V_Or_Uninitialized)

  let update_uninitialize ~validity ~offsets ~size t =
    let v = V_Or_Uninitialized.uninitialized in
    update ~validity ~exact:true ~offsets ~size v t

  let from_string s =
    (* Iterate on s + null terminator; same signature as List.fold_left *)
    let fold_string f acc s =
      let acc = ref acc in
      for i = 0 to String.length s - 1 do
        let v = V_Or_Uninitialized.initialized (V.of_char s.[i]) in
        acc := f !acc v;
      done;
      f !acc V_Or_Uninitialized.singleton_zero (** add null terminator *)
    in
    let size_char = Integer.of_int (Cil.bitsSizeOfInt IChar) in
    of_list fold_string s size_char

  let from_wstring s =
    let conv v = V_Or_Uninitialized.initialized (V.of_int64 v) in
    let fold f acc l = List.fold_left (fun acc v -> f acc (conv v)) acc l in
    let size_wchar = Integer.of_int Cil.(bitsSizeOf theMachine.wcharType) in
    of_list fold (s @ [0L]) size_wchar

  let from_cstring = function
    | Base.CSWstring w -> from_wstring w
    | Base.CSString s -> from_string s

  (* Note: it may be surprising that an offsetmap of top_ival repeated
     on 32 bits gives a state space of size 3^32. Indeed each bit
     belongs to {-1,0,1}. *)
  let cardinal_estimate offsetmap =
    let f (start,stop) (value, size, _) accu =
      let cardinal = V_Or_Uninitialized.cardinal_estimate value size in
      (* There are some bottom values bound to offsetmaps, for
         instance before the minimum of absolute valid range, that
         have a cardinal of zero; we ignore them. *)
      let cardinal =
        if Integer.is_zero cardinal then Integer.one else cardinal
      in
      let cardinalf = CardinalEstimate.of_integer cardinal in
      let repeat = Integer.(div (length start stop) size) in
      (* If a value is "cut", we still count it as if it were whole. *)
      let repeat = Integer.(max repeat one) in
      let cardinalf_repeated = CardinalEstimate.power cardinalf repeat in
      CardinalEstimate.mul accu cardinalf_repeated
    in
    fold f offsetmap CardinalEstimate.one
end

module Default_offsetmap = struct

  module StringOffsetmaps =
    State_builder.Int_hashtbl
      (V_Offsetmap)
      (struct
         let name = "Cvalue.Default_offsetmap.StringOffsetmaps"
         let dependencies = [ Ast.self ]
         let size = 17
       end)
  let () = Ast.add_monotonic_state StringOffsetmaps.self

  let default_offsetmap base =
    let aux validity v =
      match V_Offsetmap.size_from_validity validity with
      | `Bottom -> `Bottom
      | `Value size -> `Map (V_Offsetmap.create_isotropic ~size v)
    in
    match base with
    | Base.Allocated (_, validity) ->
      aux validity V_Or_Uninitialized.bottom
    | Base.Var (_, validity) | Base.CLogic_Var (_, _, validity) ->
      aux validity V_Or_Uninitialized.uninitialized
    | Base.Null ->
      let validity = Base.validity base in
      (* The map we create is not faithful for Null: this is not a problem in
         practice, because the Null base is always bound to something correct
         in module Value/Initial_state, or is invalid. *)
      aux validity V_Or_Uninitialized.bottom
    | Base.String (id,lit) ->
      try
        `Map (StringOffsetmaps.find id)
      with Not_found ->
        let o = V_Offsetmap.from_cstring lit in
        StringOffsetmaps.add id o;
        `Map o

  let uninitialized_offsetmap base = 
    match base with
    | Base.Var _ | Base.CLogic_Var _ | Base.Null | Base.Allocated _ ->
      begin
        match Base.validity base with
        | Base.Empty -> `Map V_Offsetmap.empty
        | Base.Invalid -> `Bottom
        | Base.Known (mn, mx) | Base.Unknown (mn, _, mx) 
        | Base.Variable {Base.min_alloc=mn;max_alloc=mx} ->
          assert (Int.ge mx mn);
          `Map (V_Offsetmap.create_isotropic ~size:(Int.succ mx)
                  V_Or_Uninitialized.uninitialized)
      end
    | Base.String (id,lit) -> 
      let is_tis = true in
      if is_tis then assert false (* TODO: check with PC *)
      else 
        try
          `Map (StringOffsetmaps.find id)
        with Not_found ->
          let o = V_Offsetmap.from_cstring lit in
          StringOffsetmaps.add id o;
          `Map o

end

module Model = struct

  include
    Lmap.Make_LOffset(V_Or_Uninitialized)(V_Offsetmap)(Default_offsetmap)

  let find_unspecified ?(conflate_bottom=true) state loc =
    find ~conflate_bottom state loc

  let find ?(conflate_bottom=true) state loc =
    let alarm, v = find_unspecified ~conflate_bottom state loc in
    alarm, V_Or_Uninitialized.get_v v

  let add_unsafe_binding ~exact mem loc v =
    add_binding ~reducing:true ~exact mem loc v

  let add_binding_unspecified ~exact mem loc v =
    add_binding ~reducing:false ~exact mem loc v

  let reduce_previous_binding state l v =
    assert (Locations.cardinal_zero_or_one l);
    let v = V_Or_Uninitialized.initialized v in
    snd (add_binding ~reducing:true ~exact:true state l v)

  let reduce_indeterminate_binding state l v =
    assert (Locations.cardinal_zero_or_one l);
    snd (add_binding ~reducing:true ~exact:true state l v)

  let reduce_binding initial_mem l v =
    let _, v_old = find initial_mem l in
    (* This function will discard any indeterminate bit in [v_old]. This is
       by design, as reduction functions must be called after evaluation
       was done. *)
    if V.equal v v_old
    then initial_mem
    else
      let v_new = V.narrow v_old v in
      if V.equal v_new v_old then initial_mem
      else if V.is_bottom v_new then bottom
      else reduce_previous_binding initial_mem l v_new
    
  let add_initial_binding mem loc v =
    snd (add_binding ~reducing:true ~exact:true mem loc v)
    
  (* Overwrites the definition of add_binding coming from Lmap, with a
     signature change. *)
  let add_binding ~exact acc loc value =
    add_binding
      ~reducing:false ~exact acc loc (V_Or_Uninitialized.initialized value)

  let add_new_base base ~size v ~size_v state  =
    let v = V_Or_Uninitialized.initialized v in
    add_new_base base ~size v ~size_v state


  let remove_variables vars state =
    let cleanup acc v = remove_base (Base.of_varinfo v) acc in
    List.fold_left cleanup state vars

  let uninitialize_blocks_locals blocks state =
    List.fold_left
      (fun acc block -> remove_variables block.blocals acc) state blocks

 let cardinal_estimate state =
   match state with
   | Bottom -> CardinalEstimate.zero
   | Top -> CardinalEstimate.infinite
   | Map(m) ->
     let count = ref (CardinalEstimate.one) in
     let f _ offsetmap =
       let offsetmap_card = V_Offsetmap.cardinal_estimate offsetmap in
       count := CardinalEstimate.mul !count offsetmap_card
     in
     iter f m;
     !count
end

(*
Local Variables:
compile-command: "make -C ../../.."
End:
*)

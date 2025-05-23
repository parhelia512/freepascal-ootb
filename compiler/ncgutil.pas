{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Helper routines for all code generators

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
unit ncgutil;

{$i fpcdefs.inc}

interface

    uses
      node,
      globtype,
      cpubase,cgbase,parabase,cgutils,
      aasmbase,aasmtai,aasmdata,aasmcpu,
      symconst,symbase,symdef,symsym,symtype
{$ifndef cpu64bitalu}
      ,cg64f32
{$endif not cpu64bitalu}
      ;

    type
      tloadregvars = (lr_dont_load_regvars, lr_load_regvars);

      pusedregvars = ^tusedregvars;
      tusedregvars = record
        intregvars, addrregvars, fpuregvars, mmregvars: Tsuperregisterworklist;
      end;

{
      Not used currently, implemented because I thought we had to
      synchronise around if/then/else as well, but not needed. May
      still be useful for SSA once we get around to implementing
      that (JM)

      pusedregvarscommon = ^tusedregvarscommon;
      tusedregvarscommon = record
        allregvars, commonregvars, myregvars: tusedregvars;
      end;
}

    procedure firstcomplex(p : tbinarynode);
    procedure maketojumpboollabels(list: TAsmList; p: tnode; truelabel, falselabel: tasmlabel);
//    procedure remove_non_regvars_from_loc(const t: tlocation; var regs:Tsuperregisterset);

    procedure location_force_mmreg(list:TAsmList;var l: tlocation;maybeconst:boolean);
    procedure location_allocate_register(list:TAsmList;out l: tlocation;def: tdef;constant: boolean);

    { loads a cgpara into a tlocation; assumes that loc.loc is already
      initialised }
    procedure gen_load_cgpara_loc(list: TAsmList; vardef: tdef; const para: TCGPara; var destloc: tlocation; reusepara: boolean);

    { allocate registers for a tlocation; assumes that loc.loc is already
      set to LOC_CREGISTER/LOC_CFPUREGISTER/... }
    procedure gen_alloc_regloc(list:TAsmList;var loc: tlocation;def: tdef);

    procedure register_maybe_adjust_setbase(list: TAsmList; opdef: tdef; var l: tlocation; setbase: aint);


    procedure alloc_proc_symbol(pd: tprocdef);
    procedure release_proc_symbol(pd:tprocdef);
    procedure gen_proc_entry_code(list:TAsmList);
    procedure gen_proc_exit_code(list:TAsmList);
    procedure gen_save_used_regs(list:TAsmList);
    procedure gen_restore_used_regs(list:TAsmList);
    procedure gen_load_para_value(list:TAsmList);

    procedure get_used_regvars(n: tnode; var rv: tusedregvars);
    { adds the regvars used in n and its children to rv.allregvars,
      those which were already in rv.allregvars to rv.commonregvars and
      uses rv.myregvars as scratch (so that two uses of the same regvar
      in a single tree to make it appear in commonregvars). Useful to
      find out which regvars are used in two different node trees
      e.g. in the "else" and "then" path, or in various case blocks }
//    procedure get_used_regvars_common(n: tnode; var rv: tusedregvarscommon);
    procedure gen_sync_regvars(list:TAsmList; var rv: tusedregvars);

    procedure gen_alloc_symtable(list:TAsmList;pd:tprocdef;st:TSymtable);
    procedure gen_free_symtable(list:TAsmList;st:TSymtable);

    procedure location_free(list: TAsmList; const location : TLocation);

    function getprocalign : shortint;

    procedure gen_load_frame_for_exceptfilter(list : TAsmList);

implementation

  uses
    cutils,cclasses,
    globals,systems,verbose,
    defutil,
    procinfo,paramgr,
    dbgbase,
    nbas,ncon,nld,nmem,nutils,
    tgobj,cgobj,hlcgobj,hlcgcpu
{$ifdef llvm}
    { override create_hlcodegen from hlcgcpu }
    , hlcgllvm
{$endif}
{$ifdef powerpc}
    , cpupi
{$endif}
{$ifdef powerpc64}
    , cpupi
{$endif}
{$ifdef SUPPORT_MMX}
    , cgx86
{$endif SUPPORT_MMX}
;


{*****************************************************************************
                                  Misc Helpers
*****************************************************************************}
{$if first_mm_imreg = 0}
  {$WARN 4044 OFF} { Comparison might be always false ... }
{$endif}

    procedure location_free(list: TAsmList; const location : TLocation);
      begin
        case location.loc of
          LOC_VOID:
            ;
          LOC_REGISTER,
          LOC_CREGISTER:
            begin
{$ifdef cpu64bitalu}
                { x86-64 system v abi:
                  structs with up to 16 bytes are returned in registers }
                if location.size in [OS_128,OS_S128] then
                  begin
                    if getsupreg(location.register)<first_int_imreg then
                      cg.ungetcpuregister(list,location.register);
                    if getsupreg(location.registerhi)<first_int_imreg then
                      cg.ungetcpuregister(list,location.registerhi);
                  end
{$else cpu64bitalu}
                if location.size in [OS_64,OS_S64] then
                  begin
                    if getsupreg(location.register64.reglo)<first_int_imreg then
                      cg.ungetcpuregister(list,location.register64.reglo);
                    if getsupreg(location.register64.reghi)<first_int_imreg then
                      cg.ungetcpuregister(list,location.register64.reghi);
                  end
{$endif cpu64bitalu}
                else
                  if getsupreg(location.register)<first_int_imreg then
                    cg.ungetcpuregister(list,location.register);
            end;
          LOC_FPUREGISTER,
          LOC_CFPUREGISTER:
            begin
              if getsupreg(location.register)<first_fpu_imreg then
                cg.ungetcpuregister(list,location.register);
            end;
          LOC_MMREGISTER,
          LOC_CMMREGISTER :
            begin
              if getsupreg(location.register)<first_mm_imreg then
                cg.ungetcpuregister(list,location.register);
            end;
          LOC_REFERENCE,
          LOC_CREFERENCE :
            begin
              if paramanager.use_fixed_stack then
                location_freetemp(list,location);
            end;
          else
            internalerror(2004110211);
        end;
      end;


    procedure firstcomplex(p : tbinarynode);
      var
        fcl, fcr: longint;
        ncl, ncr: longint;
      begin
         { always calculate boolean AND and OR from left to right }
         if (p.nodetype in [orn,andn]) and
            is_boolean(p.left.resultdef) then
           begin
             if nf_swapped in p.flags then
               internalerror(200709253);
           end
         else
           begin
             fcl:=node_resources_fpu(p.left);
             fcr:=node_resources_fpu(p.right);
             ncl:=node_complexity(p.left);
             ncr:=node_complexity(p.right);
             { We swap left and right if
                a) right needs more floating point registers than left, and
                   left needs more than 0 floating point registers (if it
                   doesn't need any, swapping won't change the floating
                   point register pressure)
                b) both left and right need an equal amount of floating
                   point registers or right needs no floating point registers,
                   and in addition right has a higher complexity than left
                   (+- needs more integer registers, but not necessarily)
             }
             if ((fcr>fcl) and
                 (fcl>0)) or
                (((fcr=fcl) or
                  (fcr=0)) and
                 (ncr>ncl)) and
                { if one tree contains nodes being conditionally executated, we cannot swap the trees
                  as the other tree might depend on all nodes being executed, this applies for example
                  for temp. create nodes with init part, they must be executed else things break, see
                  issue #34653
                }
                 not(has_conditional_nodes(p.right)) then
               p.swapleftright
           end;
      end;


    procedure maketojumpboollabels(list: TAsmList; p: tnode; truelabel, falselabel: tasmlabel);
    {
      produces jumps to true respectively false labels using boolean expressions
    }
      var
        opsize : tcgsize;
        storepos : tfileposinfo;
        tmpreg : tregister;
      begin
         if nf_error in p.flags then
           exit;
         storepos:=current_filepos;
         current_filepos:=p.fileinfo;
         if is_boolean(p.resultdef) then
           begin
              if is_constboolnode(p) then
                begin
                   if Tordconstnode(p).value.uvalue<>0 then
                     cg.a_jmp_always(list,truelabel)
                   else
                     cg.a_jmp_always(list,falselabel)
                end
              else
                begin
                   opsize:=def_cgsize(p.resultdef);
                   case p.location.loc of
                     LOC_SUBSETREG,LOC_CSUBSETREG:
                       begin
                         if p.location.sreg.bitlen=1 then
                           begin
                             tmpreg:=cg.getintregister(list,p.location.sreg.subsetregsize);
                             hlcg.a_op_const_reg_reg(list,OP_AND,cgsize_orddef(p.location.sreg.subsetregsize),1 shl p.location.sreg.startbit,p.location.sreg.subsetreg,tmpreg);
                           end
                         else
                           begin
                             tmpreg:=cg.getintregister(list,OS_INT);
                             hlcg.a_load_loc_reg(list,p.resultdef,osuinttype,p.location,tmpreg);
                           end;
                         cg.a_cmp_const_reg_label(list,OS_INT,OC_NE,0,tmpreg,truelabel);
                         cg.a_jmp_always(list,falselabel);
                       end;
                     LOC_SUBSETREF,LOC_CSUBSETREF:
                       begin
                         if (p.location.sref.bitindexreg=NR_NO) and (p.location.sref.bitlen=1) then
                           begin
                             tmpreg:=cg.getintregister(list,OS_INT);
                             hlcg.a_load_ref_reg(list,u8inttype,osuinttype,p.location.sref.ref,tmpreg);

                             if target_info.endian=endian_big then
                               hlcg.a_op_const_reg_reg(list,OP_AND,osuinttype,1 shl (8-(p.location.sref.startbit+1)),tmpreg,tmpreg)
                             else
                               hlcg.a_op_const_reg_reg(list,OP_AND,osuinttype,1 shl p.location.sref.startbit,tmpreg,tmpreg);
                           end
                         else
                           begin
                             tmpreg:=cg.getintregister(list,OS_INT);
                             hlcg.a_load_loc_reg(list,p.resultdef,osuinttype,p.location,tmpreg);
                           end;
                         cg.a_cmp_const_reg_label(list,OS_INT,OC_NE,0,tmpreg,truelabel);
                         cg.a_jmp_always(list,falselabel);
                       end;
                     LOC_CREGISTER,LOC_REGISTER,LOC_CREFERENCE,LOC_REFERENCE :
                       begin
{$ifdef cpu64bitalu}
                         if opsize in [OS_128,OS_S128] then
                           begin
                             hlcg.location_force_reg(list,p.location,p.resultdef,cgsize_orddef(opsize),true);
                             tmpreg:=cg.getintregister(list,OS_64);
                             cg.a_op_reg_reg_reg(list,OP_OR,OS_64,p.location.register128.reglo,p.location.register128.reghi,tmpreg);
                             location_reset(p.location,LOC_REGISTER,OS_64);
                             p.location.register:=tmpreg;
                             opsize:=OS_64;
                           end;
{$else cpu64bitalu}
                         if opsize in [OS_64,OS_S64] then
                           begin
                             hlcg.location_force_reg(list,p.location,p.resultdef,cgsize_orddef(opsize),true);
                             tmpreg:=cg.getintregister(list,OS_32);
                             cg.a_op_reg_reg_reg(list,OP_OR,OS_32,p.location.register64.reglo,p.location.register64.reghi,tmpreg);
                             location_reset(p.location,LOC_REGISTER,OS_32);
                             p.location.register:=tmpreg;
                             opsize:=OS_32;
                           end;
{$endif cpu64bitalu}
                         cg.a_cmp_const_loc_label(list,opsize,OC_NE,0,p.location,truelabel);
                         cg.a_jmp_always(list,falselabel);
                       end;
                     LOC_JUMP:
                       begin
                         if truelabel<>p.location.truelabel then
                           begin
                             cg.a_label(list,p.location.truelabel);
                             cg.a_jmp_always(list,truelabel);
                           end;
                         if falselabel<>p.location.falselabel then
                           begin
                             cg.a_label(list,p.location.falselabel);
                             cg.a_jmp_always(list,falselabel);
                           end;
                       end;
{$ifdef cpuflags}
                     LOC_FLAGS :
                       begin
                         cg.a_jmp_flags(list,p.location.resflags,truelabel);
                         cg.a_reg_dealloc(list,NR_DEFAULTFLAGS);
                         cg.a_jmp_always(list,falselabel);
                       end;
{$endif cpuflags}
                     else
                       begin
                         printnode(output,p);
                         internalerror(200308241);
                       end;
                   end;
                end;
              location_reset_jump(p.location,truelabel,falselabel);
           end
         else
           internalerror(200112305);
         current_filepos:=storepos;
      end;


        (*
        This code needs fixing. It is not safe to use rgint; on the m68000 it
        would be rgaddr.

    procedure remove_non_regvars_from_loc(const t: tlocation; var regs:Tsuperregisterset);
      begin
        case t.loc of
          LOC_REGISTER:
            begin
              { can't be a regvar, since it would be LOC_CREGISTER then }
              exclude(regs,getsupreg(t.register));
              if t.register64.reghi<>NR_NO then
                exclude(regs,getsupreg(t.register64.reghi));
            end;
          LOC_CREFERENCE,LOC_REFERENCE:
            begin
              if not(cs_opt_regvar in current_settings.optimizerswitches) or
                 (getsupreg(t.reference.base) in cg.rgint.usableregs) then
                exclude(regs,getsupreg(t.reference.base));
              if not(cs_opt_regvar in current_settings.optimizerswitches) or
                 (getsupreg(t.reference.index) in cg.rgint.usableregs) then
                exclude(regs,getsupreg(t.reference.index));
            end;
        end;
      end;
        *)


{*****************************************************************************
                                     TLocation
*****************************************************************************}


    procedure register_maybe_adjust_setbase(list: TAsmList; opdef: tdef; var l: tlocation; setbase: aint);
      var
        tmpreg: tregister;
      begin
        if (setbase<>0) then
          begin
            if not(l.loc in [LOC_REGISTER,LOC_CREGISTER]) then
              internalerror(2007091502);
            { subtract the setbase }
            case l.loc of
              LOC_CREGISTER:
                begin
                  tmpreg := hlcg.getintregister(list,opdef);
                  hlcg.a_op_const_reg_reg(list,OP_SUB,opdef,setbase,l.register,tmpreg);
                  l.loc:=LOC_REGISTER;
                  l.register:=tmpreg;
                end;
              LOC_REGISTER:
                begin
                  hlcg.a_op_const_reg(list,OP_SUB,opdef,setbase,l.register);
                end;
            end;
          end;
      end;


    procedure location_force_mmreg(list:TAsmList;var l: tlocation;maybeconst:boolean);
      var
        reg : tregister;
      begin
        if (l.loc<>LOC_MMREGISTER)  and
           ((l.loc<>LOC_CMMREGISTER) or (not maybeconst)) then
          begin
            reg:=cg.getmmregister(list,OS_VECTOR);
            cg.a_loadmm_loc_reg(list,OS_VECTOR,l,reg,nil);
            location_freetemp(list,l);
            location_reset(l,LOC_MMREGISTER,OS_VECTOR);
            l.register:=reg;
          end;
      end;


    procedure location_allocate_register(list: TAsmList;out l: tlocation;def: tdef;constant: boolean);
      begin
        l.size:=def_cgsize(def);
        if (def.typ=floatdef) and
           not(cs_fp_emulation in current_settings.moduleswitches) then
          begin
            if use_vectorfpu(def) then
              begin
                if constant then
                  location_reset(l,LOC_CMMREGISTER,l.size)
                else
                  location_reset(l,LOC_MMREGISTER,l.size);
                l.register:=cg.getmmregister(list,l.size);
              end
            else
              begin
                if constant then
                  location_reset(l,LOC_CFPUREGISTER,l.size)
                else
                  location_reset(l,LOC_FPUREGISTER,l.size);
                l.register:=cg.getfpuregister(list,l.size);
              end;
          end
        else
          begin
            if constant then
              location_reset(l,LOC_CREGISTER,l.size)
            else
              location_reset(l,LOC_REGISTER,l.size);
{$ifdef cpu64bitalu}
            if l.size in [OS_128,OS_S128,OS_F128] then
              begin
                l.register128.reglo:=cg.getintregister(list,OS_64);
                l.register128.reghi:=cg.getintregister(list,OS_64);
              end
            else
{$else cpu64bitalu}
            if l.size in [OS_64,OS_S64,OS_F64] then
              begin
                l.register64.reglo:=cg.getintregister(list,OS_32);
                l.register64.reghi:=cg.getintregister(list,OS_32);
              end
            else
{$endif cpu64bitalu}
            { Note: for widths of records (and maybe objects, classes, etc.) an
                    address register could be set here, but that is later
                    changed to an intregister neverthless when in the
                    tcgassignmentnode thlcgobj.maybe_change_load_node_reg is
                    called for the temporary node; so the workaround for now is
                    to fix the symptoms... }
              l.register:=hlcg.getregisterfordef(list,def);
          end;
      end;


{****************************************************************************
                            Init/Finalize Code
****************************************************************************}

    { generates the code for incrementing the reference count of parameters and
      initialize out parameters }
    procedure init_paras(p:TObject;arg:pointer);
      var
        href : treference;
        hsym : tparavarsym;
        eldef : tdef;
        list : TAsmList;
        needs_inittable : boolean;
      begin
        list:=TAsmList(arg);
        if (tsym(p).typ=paravarsym) then
         begin
           needs_inittable:=is_managed_type(tparavarsym(p).vardef);
           if not needs_inittable then
             exit;
           case tparavarsym(p).varspez of
             vs_value :
               begin
                 { variants are already handled by the call to fpc_variant_copy_overwrite if
                   they are passed by reference }
                 if not((tparavarsym(p).vardef.typ=variantdef) and
                    paramanager.push_addr_param(tparavarsym(p).varspez,tparavarsym(p).vardef,current_procinfo.procdef.proccalloption)) then
                   begin
                     hlcg.location_get_data_ref(list,tparavarsym(p).vardef,tparavarsym(p).initialloc,href,
                       is_open_array(tparavarsym(p).vardef) or
                       ((target_info.system in systems_caller_copy_addr_value_para) and
                        paramanager.push_addr_param(vs_value,tparavarsym(p).vardef,current_procinfo.procdef.proccalloption)),
                        sizeof(pint));
                     if is_open_array(tparavarsym(p).vardef) then
                       begin
                         { open arrays do not contain correct element count in their rtti,
                           the actual count must be passed separately. }
                         hsym:=tparavarsym(get_high_value_sym(tparavarsym(p)));
                         eldef:=tarraydef(tparavarsym(p).vardef).elementdef;
                         if not assigned(hsym) then
                           internalerror(201003031);
                         hlcg.g_array_rtti_helper(list,eldef,href,hsym.initialloc,'fpc_addref_array');
                       end
                     else
                      hlcg.g_incrrefcount(list,tparavarsym(p).vardef,href);
                   end;
               end;
             vs_out :
               begin
                 { we have no idea about the alignment at the callee side,
                   and the user also cannot specify "unaligned" here, so
                   assume worst case }
                 hlcg.location_get_data_ref(list,tparavarsym(p).vardef,tparavarsym(p).initialloc,href,true,1);
                 if is_open_array(tparavarsym(p).vardef) then
                   begin
                     hsym:=tparavarsym(get_high_value_sym(tparavarsym(p)));
                     eldef:=tarraydef(tparavarsym(p).vardef).elementdef;
                     if not assigned(hsym) then
                       internalerror(201103033);
                     hlcg.g_array_rtti_helper(list,eldef,href,hsym.initialloc,'fpc_initialize_array');
                   end
                 else
                   hlcg.g_initialize(list,tparavarsym(p).vardef,href);
               end;
           end;
         end;
      end;


    procedure gen_alloc_regloc(list:TAsmList;var loc: tlocation;def: tdef);
      begin
        case loc.loc of
          LOC_CREGISTER:
            begin
{$ifdef cpu64bitalu}
              if loc.size in [OS_128,OS_S128] then
                begin
                  loc.register128.reglo:=cg.getintregister(list,OS_64);
                  loc.register128.reghi:=cg.getintregister(list,OS_64);
                end
              else
{$else cpu64bitalu}
              if loc.size in [OS_64,OS_S64] then
                begin
                  loc.register64.reglo:=cg.getintregister(list,OS_32);
                  loc.register64.reghi:=cg.getintregister(list,OS_32);
                end
              else
{$endif cpu64bitalu}
                if hlcg.def2regtyp(def)=R_ADDRESSREGISTER then
                  loc.register:=hlcg.getaddressregister(list,def)
                else
                  loc.register:=cg.getintregister(list,loc.size);
            end;
          LOC_CFPUREGISTER:
            begin
              loc.register:=cg.getfpuregister(list,loc.size);
            end;
          LOC_CMMREGISTER:
            begin
             loc.register:=cg.getmmregister(list,loc.size);
            end;
        end;
      end;


    procedure gen_alloc_regvar(list:TAsmList;sym: tabstractnormalvarsym; allocreg: boolean);
      var
        usedef: tdef;
        varloc: tai_varloc;
      begin
        if allocreg then
          begin
            if sym.typ=paravarsym then
              usedef:=tparavarsym(sym).paraloc[calleeside].def
            else
              usedef:=sym.vardef;
            gen_alloc_regloc(list,sym.initialloc,usedef);
          end;
        if (pi_has_label in current_procinfo.flags) then
          begin
            { Allocate register already, to prevent first allocation to be
              inside a loop }
{$if defined(cpu64bitalu)}
            if sym.initialloc.size in [OS_128,OS_S128] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register128.reglo);
                cg.a_reg_sync(list,sym.initialloc.register128.reghi);
              end
            else
{$elseif defined(cpu32bitalu)}
            if sym.initialloc.size in [OS_64,OS_S64] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register64.reglo);
                cg.a_reg_sync(list,sym.initialloc.register64.reghi);
              end
            else
{$elseif defined(cpu16bitalu)}
            if sym.initialloc.size in [OS_64,OS_S64] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register64.reglo);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register64.reglo));
                cg.a_reg_sync(list,sym.initialloc.register64.reghi);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register64.reghi));
              end
            else
            if sym.initialloc.size in [OS_32,OS_S32] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register));
              end
            else
{$elseif defined(cpu8bitalu)}
            if sym.initialloc.size in [OS_64,OS_S64] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register64.reglo);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register64.reglo));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(sym.initialloc.register64.reglo)));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(sym.initialloc.register64.reglo))));
                cg.a_reg_sync(list,sym.initialloc.register64.reghi);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register64.reghi));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(sym.initialloc.register64.reghi)));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(sym.initialloc.register64.reghi))));
              end
            else
            if sym.initialloc.size in [OS_32,OS_S32] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(sym.initialloc.register)));
                cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(sym.initialloc.register))));
              end
            else
            if sym.initialloc.size in [OS_16,OS_S16] then
              begin
                cg.a_reg_sync(list,sym.initialloc.register);
                cg.a_reg_sync(list,cg.GetNextReg(sym.initialloc.register));
              end
            else
{$endif}
             cg.a_reg_sync(list,sym.initialloc.register);
          end;
{$ifdef cpu64bitalu}
        if (sym.initialloc.size in [OS_128,OS_S128]) then
          varloc:=tai_varloc.create128(sym,sym.initialloc.register,sym.initialloc.registerhi)
{$else cpu64bitalu}
        if (sym.initialloc.size in [OS_64,OS_S64]) then
          varloc:=tai_varloc.create64(sym,sym.initialloc.register,sym.initialloc.registerhi)
{$endif cpu64bitalu}
        else
          varloc:=tai_varloc.create(sym,sym.initialloc.register);
        list.concat(varloc);
      end;


    procedure gen_load_cgpara_loc(list: TAsmList; vardef: tdef; const para: TCGPara; var destloc: tlocation; reusepara: boolean);

      procedure unget_para(const paraloc:TCGParaLocation);
        begin
           case paraloc.loc of
             LOC_REGISTER :
               begin
                 if getsupreg(paraloc.register)<first_int_imreg then
                   cg.ungetcpuregister(list,paraloc.register);
               end;
             LOC_MMREGISTER :
               begin
                 if getsupreg(paraloc.register)<first_mm_imreg then
                   cg.ungetcpuregister(list,paraloc.register);
               end;
             LOC_FPUREGISTER :
               begin
                 if getsupreg(paraloc.register)<first_fpu_imreg then
                   cg.ungetcpuregister(list,paraloc.register);
               end;
           end;
        end;

      var
        paraloc   : pcgparalocation;
        href      : treference;
        sizeleft  : aint;
        tempref   : treference;
        loadsize  : tcgint;
        tempreg  : tregister;
{$ifdef mips}
        //tmpreg   : tregister;
{$endif mips}
{$ifndef cpu64bitalu}
        reg64    : tregister64;
{$if defined(cpu8bitalu)}
        curparaloc : PCGParaLocation;
{$endif defined(cpu8bitalu)}
{$endif not cpu64bitalu}
      begin
        paraloc:=para.location;
        if not assigned(paraloc) then
          internalerror(200408203);
        { skip e.g. empty records }
        if (paraloc^.loc = LOC_VOID) then
          exit;
        case destloc.loc of
          LOC_REFERENCE :
            begin
              { If the parameter location is reused we don't need to copy
                anything }
              if not reusepara then
                begin
                  href:=destloc.reference;
                  sizeleft:=para.intsize;
                  while assigned(paraloc) do
                    begin
                      if (paraloc^.size=OS_NO) then
                        begin
                          { Can only be a reference that contains the rest
                            of the parameter }
                          if (paraloc^.loc<>LOC_REFERENCE) or
                             assigned(paraloc^.next) then
                            internalerror(2005013010);
                          cg.a_load_cgparaloc_ref(list,paraloc^,href,sizeleft,destloc.reference.alignment);
                          inc(href.offset,sizeleft);
                          sizeleft:=0;
                        end
                      else
                        begin
                          { the min(...) call ensures that we do not store more than place is left as
                             paraloc^.size could be bigger than destloc.size of a parameter occupies a full register
                             and as on big endian system the parameters might be left aligned, we have to work
                             with the full register size for paraloc^.size }
                          if tcgsize2size[destloc.size]<>0 then
                            loadsize:=min(min(tcgsize2size[paraloc^.size],tcgsize2size[destloc.size]),sizeleft)
                          else
                            loadsize:=min(tcgsize2size[paraloc^.size],sizeleft);

                          cg.a_load_cgparaloc_ref(list,paraloc^,href,loadsize,destloc.reference.alignment);
                          inc(href.offset,loadsize);
                          dec(sizeleft,loadsize);
                        end;
                      unget_para(paraloc^);
                      paraloc:=paraloc^.next;
                    end;
                end;
            end;
          LOC_REGISTER,
          LOC_CREGISTER :
            begin
{$ifdef cpu64bitalu}
              if (para.size in [OS_128,OS_S128,OS_F128]) and
                 ({ in case of fpu emulation, or abi's that pass fpu values
                    via integer registers }
                  (vardef.typ=floatdef) or
                   is_methodpointer(vardef) or
                   is_record(vardef)) then
                begin
                  case paraloc^.loc of
                    LOC_REGISTER,
                    LOC_MMREGISTER:
                      begin
                        if not assigned(paraloc^.next) then
                          internalerror(200410104);
                        case tcgsize2size[paraloc^.size] of
                          8:
                            begin
                              if (target_info.endian=ENDIAN_BIG) then
                                begin
                                  { paraloc^ -> high
                                    paraloc^.next -> low }
                                  unget_para(paraloc^);
                                  gen_alloc_regloc(list,destloc,vardef);
                                  { reg->reg, alignment is irrelevant }
                                  cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,destloc.register128.reghi,8);
                                  unget_para(paraloc^.next^);
                                  cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^.next^,destloc.register128.reglo,8);
                                end
                              else
                                begin
                                  { paraloc^ -> low
                                    paraloc^.next -> high }
                                  unget_para(paraloc^);
                                  gen_alloc_regloc(list,destloc,vardef);
                                  cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,destloc.register128.reglo,8);
                                  unget_para(paraloc^.next^);
                                  cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^.next^,destloc.register128.reghi,8);
                                end;
                            end;
                          4:
                            begin
                              { The 128-bit parameter is located in 4 32-bit MM registers.
                                It is needed to copy them to 2 64-bit int registers.
                                A code generator or a target cpu must support loading of a 32-bit MM register to
                                a 64-bit int register, zero extending it. }
                              if target_info.endian=ENDIAN_BIG then
                                internalerror(2018101702);  // Big endian support not implemented yet
                              gen_alloc_regloc(list,destloc,vardef);
                              tempreg:=cg.getintregister(list,OS_64);
                              // Low part of the 128-bit param
                              unget_para(paraloc^);
                              cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,tempreg,4);
                              paraloc:=paraloc^.next;
                              if paraloc=nil then
                                internalerror(2018101703);
                              unget_para(paraloc^);
                              cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,destloc.register128.reglo,4);
                              cg.a_op_const_reg(list,OP_SHL,OS_64,32,destloc.register128.reglo);
                              cg.a_op_reg_reg(list,OP_OR,OS_64,tempreg,destloc.register128.reglo);
                              // High part of the 128-bit param
                              paraloc:=paraloc^.next;
                              if paraloc=nil then
                                internalerror(2018101704);
                              unget_para(paraloc^);
                              cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,tempreg,4);
                              paraloc:=paraloc^.next;
                              if paraloc=nil then
                                internalerror(2018101705);
                              unget_para(paraloc^);
                              cg.a_load_cgparaloc_anyreg(list,OS_64,paraloc^,destloc.register128.reghi,4);
                              cg.a_op_const_reg(list,OP_SHL,OS_64,32,destloc.register128.reghi);
                              cg.a_op_reg_reg(list,OP_OR,OS_64,tempreg,destloc.register128.reghi);
                            end
                          else
                            internalerror(2018101701);
                        end;
                      end;
                    LOC_REFERENCE:
                      begin
                        gen_alloc_regloc(list,destloc,vardef);
                        reference_reset_base(href,paraloc^.reference.index,paraloc^.reference.offset,ctempposinvalid,para.alignment,[]);
                        cg128.a_load128_ref_reg(list,href,destloc.register128);
                        unget_para(paraloc^);
                      end;
                    else
                      internalerror(2012090607);
                  end
                end
              else
{$else cpu64bitalu}
              if (para.size in [OS_64,OS_S64,OS_F64]) and
                 (is_64bit(vardef) or
                  { in case of fpu emulation, or abi's that pass fpu values
                    via integer registers }
                  (vardef.typ=floatdef) or
                   is_methodpointer(vardef) or
                   is_record(vardef)) then
                begin
                  case paraloc^.loc of
                    LOC_REGISTER:
                      begin
                        case para.locations_count of
{$if defined(cpu8bitalu)}
                          { 8 paralocs? }
                          8:
                            if (target_info.endian=ENDIAN_BIG) then
                              begin
                                { is there any big endian 8 bit ALU/16 bit Addr CPU? }
                                internalerror(2015041003);
                                { paraloc^ -> high
                                  paraloc^.next^.next^.next^.next -> low }
                                unget_para(paraloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                { reg->reg, alignment is irrelevant }
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^,cg.GetNextReg(destloc.register64.reghi),1);
                                unget_para(paraloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^,destloc.register64.reghi,1);
                                unget_para(paraloc^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^,cg.GetNextReg(destloc.register64.reglo),1);
                                unget_para(paraloc^.next^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^.next^,destloc.register64.reglo,1);
                              end
                            else
                              begin
                                { paraloc^ -> low
                                  paraloc^.next^.next^.next^.next -> high }
                                curparaloc:=paraloc;
                                unget_para(curparaloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^,destloc.register64.reglo,2);
                                unget_para(curparaloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^,cg.GetNextReg(destloc.register64.reglo),1);
                                unget_para(curparaloc^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^.next^,cg.GetNextReg(cg.GetNextReg(destloc.register64.reglo)),1);
                                unget_para(curparaloc^.next^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^.next^.next^,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(destloc.register64.reglo))),1);

                                curparaloc:=paraloc^.next^.next^.next^.next;
                                unget_para(curparaloc^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^,destloc.register64.reghi,2);
                                unget_para(curparaloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^,cg.GetNextReg(destloc.register64.reghi),1);
                                unget_para(curparaloc^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^.next^,cg.GetNextReg(cg.GetNextReg(destloc.register64.reghi)),1);
                                unget_para(curparaloc^.next^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_8,curparaloc^.next^.next^.next^,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(destloc.register64.reghi))),1);
                              end;
{$endif defined(cpu8bitalu)}
{$if defined(cpu16bitalu) or defined(cpu8bitalu)}
                          { 4 paralocs? }
                          4:
                            if (target_info.endian=ENDIAN_BIG) then
                              begin
                                { paraloc^ -> high
                                  paraloc^.next^.next -> low }
                                unget_para(paraloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                { reg->reg, alignment is irrelevant }
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^,cg.GetNextReg(destloc.register64.reghi),2);
                                unget_para(paraloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^,destloc.register64.reghi,2);
                                unget_para(paraloc^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^,cg.GetNextReg(destloc.register64.reglo),2);
                                unget_para(paraloc^.next^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^.next^,destloc.register64.reglo,2);
                              end
                            else
                              begin
                                { paraloc^ -> low
                                  paraloc^.next^.next -> high }
                                unget_para(paraloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^,destloc.register64.reglo,2);
                                unget_para(paraloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^,cg.GetNextReg(destloc.register64.reglo),2);
                                unget_para(paraloc^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^,destloc.register64.reghi,2);
                                unget_para(paraloc^.next^.next^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_16,paraloc^.next^.next^.next^,cg.GetNextReg(destloc.register64.reghi),2);
                              end;
{$endif defined(cpu16bitalu) or defined(cpu8bitalu)}
                          2:
                            if (target_info.endian=ENDIAN_BIG) then
                              begin
                                { paraloc^ -> high
                                  paraloc^.next -> low }
                                unget_para(paraloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                { reg->reg, alignment is irrelevant }
                                cg.a_load_cgparaloc_anyreg(list,OS_32,paraloc^,destloc.register64.reghi,4);
                                unget_para(paraloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_32,paraloc^.next^,destloc.register64.reglo,4);
                              end
                            else
                              begin
                                { paraloc^ -> low
                                  paraloc^.next -> high }
                                unget_para(paraloc^);
                                gen_alloc_regloc(list,destloc,vardef);
                                cg.a_load_cgparaloc_anyreg(list,OS_32,paraloc^,destloc.register64.reglo,4);
                                unget_para(paraloc^.next^);
                                cg.a_load_cgparaloc_anyreg(list,OS_32,paraloc^.next^,destloc.register64.reghi,4);
                              end;
                          else
                            { unexpected number of paralocs }
                            internalerror(200410104);
                        end;
                      end;
                    LOC_REFERENCE:
                      begin
                        gen_alloc_regloc(list,destloc,vardef);
                        reference_reset_base(href,paraloc^.reference.index,paraloc^.reference.offset,ctempposinvalid,para.alignment,[]);
                        cg64.a_load64_ref_reg(list,href,destloc.register64);
                        unget_para(paraloc^);
                      end;
                    else
                      internalerror(2005101501);
                  end
                end
              else
{$endif cpu64bitalu}
                begin
                  if assigned(paraloc^.next) then
                    begin
                      if (destloc.size in [OS_PAIR,OS_SPAIR]) and
                        (para.Size in [OS_PAIR,OS_SPAIR]) then
                        begin
                          unget_para(paraloc^);
                          gen_alloc_regloc(list,destloc,vardef);
                          cg.a_load_cgparaloc_anyreg(list,OS_INT,paraloc^,destloc.register,sizeof(aint));
                          unget_para(paraloc^.Next^);
                          {$if defined(cpu16bitalu) or defined(cpu8bitalu)}
                            cg.a_load_cgparaloc_anyreg(list,OS_INT,paraloc^.Next^,cg.GetNextReg(destloc.register),sizeof(aint));
                          {$else}
                            cg.a_load_cgparaloc_anyreg(list,OS_INT,paraloc^.Next^,destloc.registerhi,sizeof(aint));
                          {$endif}
                        end
{$if defined(cpu8bitalu)}
                      else if (destloc.size in [OS_32,OS_S32]) and
                        (para.Size in [OS_32,OS_S32]) then
                        begin
                          unget_para(paraloc^);
                          gen_alloc_regloc(list,destloc,vardef);
                          cg.a_load_cgparaloc_anyreg(list,OS_8,paraloc^,destloc.register,sizeof(aint));
                          unget_para(paraloc^.Next^);
                          cg.a_load_cgparaloc_anyreg(list,OS_8,paraloc^.Next^,cg.GetNextReg(destloc.register),sizeof(aint));
                          unget_para(paraloc^.Next^.Next^);
                          cg.a_load_cgparaloc_anyreg(list,OS_8,paraloc^.Next^.Next^,cg.GetNextReg(cg.GetNextReg(destloc.register)),sizeof(aint));
                          unget_para(paraloc^.Next^.Next^.Next^);
                          cg.a_load_cgparaloc_anyreg(list,OS_8,paraloc^.Next^.Next^.Next^,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(destloc.register))),sizeof(aint));
                        end
{$endif defined(cpu8bitalu)}
                      else
                        begin
                          { this can happen if a parameter is spread over
                            multiple paralocs, e.g. if a record with two single
                            fields must be passed in two single precision
                            registers }
                          { does it fit in the register of destloc? }
                          sizeleft:=para.intsize;
                          if sizeleft<>vardef.size then
                            internalerror(2014122806);
                          if sizeleft<>tcgsize2size[destloc.size] then
                            internalerror(200410105);
                          { store everything first to memory, then load it in
                            destloc }
                          tg.gettemp(list,sizeleft,sizeleft,tt_persistent,tempref);
                          gen_alloc_regloc(list,destloc,vardef);
                          while sizeleft>0 do
                            begin
                              if not assigned(paraloc) then
                                internalerror(2014122807);
                              unget_para(paraloc^);
                              cg.a_load_cgparaloc_ref(list,paraloc^,tempref,sizeleft,newalignment(para.alignment,para.intsize-sizeleft));
                              if (paraloc^.size=OS_NO) and
                                 assigned(paraloc^.next) then
                                internalerror(2014122805);
                              inc(tempref.offset,tcgsize2size[paraloc^.size]);
                              dec(sizeleft,tcgsize2size[paraloc^.size]);
                              paraloc:=paraloc^.next;
                            end;
                          dec(tempref.offset,para.intsize);
                          cg.a_load_ref_reg(list,para.size,para.size,tempref,destloc.register);
                          tg.ungettemp(list,tempref);
                        end;
                    end
                  else
                    begin
                      unget_para(paraloc^);
                      gen_alloc_regloc(list,destloc,vardef);
                      { we can't directly move regular registers into fpu
                        registers }
                      if getregtype(paraloc^.register)=R_FPUREGISTER then
                        begin
                          { store everything first to memory, then load it in
                            destloc }
                          tg.gettemp(list,tcgsize2size[paraloc^.size],para.intsize,tt_persistent,tempref);
                          cg.a_load_cgparaloc_ref(list,paraloc^,tempref,tcgsize2size[paraloc^.size],tempref.alignment);
                          cg.a_load_ref_reg(list,int_cgsize(tcgsize2size[paraloc^.size]),destloc.size,tempref,destloc.register);
                          tg.ungettemp(list,tempref);
                        end
                      else
                        cg.a_load_cgparaloc_anyreg(list,destloc.size,paraloc^,destloc.register,sizeof(aint));
                    end;
                end;
            end;
          LOC_FPUREGISTER,
          LOC_CFPUREGISTER :
            begin
{$ifdef mips}
              if (destloc.size = paraloc^.Size) and
                 (paraloc^.Loc in [LOC_FPUREGISTER,LOC_CFPUREGISTER,LOC_REFERENCE,LOC_CREFERENCE]) then
                begin
                  unget_para(paraloc^);
                  gen_alloc_regloc(list,destloc,vardef);
                  cg.a_load_cgparaloc_anyreg(list,destloc.size,paraloc^,destloc.register,para.alignment);
                end
              else if (destloc.size = OS_F32) and
                 (paraloc^.Loc in [LOC_REGISTER,LOC_CREGISTER]) then
                begin
                  gen_alloc_regloc(list,destloc,vardef);
                  unget_para(paraloc^);
                  list.Concat(taicpu.op_reg_reg(A_MTC1,paraloc^.register,destloc.register));
                end
{ TODO: Produces invalid code, needs fixing together with regalloc setup. }
{
              else if (destloc.size = OS_F64) and
                      (paraloc^.Loc in [LOC_REGISTER,LOC_CREGISTER]) and
                      (paraloc^.next^.Loc in [LOC_REGISTER,LOC_CREGISTER]) then
                begin
                  gen_alloc_regloc(list,destloc,vardef);

                  tmpreg:=destloc.register;
                  unget_para(paraloc^);
                  list.Concat(taicpu.op_reg_reg(A_MTC1,paraloc^.register,tmpreg));
                  setsupreg(tmpreg,getsupreg(tmpreg)+1);
                  unget_para(paraloc^.next^);
                  list.Concat(taicpu.op_reg_reg(A_MTC1,paraloc^.Next^.register,tmpreg));
                end
}
              else
                begin
                  sizeleft := TCGSize2Size[destloc.size];
                  tg.GetTemp(list,sizeleft,sizeleft,tt_normal,tempref);
                  href:=tempref;
                  while assigned(paraloc) do
                    begin
                      unget_para(paraloc^);
                      cg.a_load_cgparaloc_ref(list,paraloc^,href,sizeleft,destloc.reference.alignment);
                      inc(href.offset,TCGSize2Size[paraloc^.size]);
                      dec(sizeleft,TCGSize2Size[paraloc^.size]);
                      paraloc:=paraloc^.next;
                    end;
                  gen_alloc_regloc(list,destloc,vardef);
                  cg.a_loadfpu_ref_reg(list,destloc.size,destloc.size,tempref,destloc.register);
                  tg.UnGetTemp(list,tempref);
                end;
{$else mips}
{$if defined(sparc) or defined(arm)}
              { Arm and Sparc passes floats in int registers, when loading to fpu register
                we need a temp }
              sizeleft := TCGSize2Size[destloc.size];
              tg.GetTemp(list,sizeleft,sizeleft,tt_normal,tempref);
              href:=tempref;
              while assigned(paraloc) do
                begin
                  unget_para(paraloc^);
                  cg.a_load_cgparaloc_ref(list,paraloc^,href,sizeleft,destloc.reference.alignment);
                  inc(href.offset,TCGSize2Size[paraloc^.size]);
                  dec(sizeleft,TCGSize2Size[paraloc^.size]);
                  paraloc:=paraloc^.next;
                end;
              gen_alloc_regloc(list,destloc,vardef);
              cg.a_loadfpu_ref_reg(list,destloc.size,destloc.size,tempref,destloc.register);
              tg.UnGetTemp(list,tempref);
{$else defined(sparc) or defined(arm)}
              unget_para(paraloc^);
              gen_alloc_regloc(list,destloc,vardef);
              { from register to register -> alignment is irrelevant }
              cg.a_load_cgparaloc_anyreg(list,destloc.size,paraloc^,destloc.register,0);
              if assigned(paraloc^.next) then
                internalerror(200410109);
{$endif defined(sparc) or defined(arm)}
{$endif mips}
            end;
          LOC_MMREGISTER,
          LOC_CMMREGISTER :
            begin
{$ifndef cpu64bitalu}
              { ARM vfp floats are passed in integer registers }
              if (para.size=OS_F64) and
                 (paraloc^.size in [OS_32,OS_S32]) and
                 use_vectorfpu(vardef) then
                begin
                  { we need 2x32bit reg }
                  if not assigned(paraloc^.next) or
                     assigned(paraloc^.next^.next) then
                    internalerror(2009112421);
                  unget_para(paraloc^.next^);
                  case paraloc^.next^.loc of
                    LOC_REGISTER:
                      tempreg:=paraloc^.next^.register;
                    LOC_REFERENCE:
                      begin
                        tempreg:=cg.getintregister(list,OS_32);
                        cg.a_load_cgparaloc_anyreg(list,OS_32,paraloc^.next^,tempreg,4);
                      end;
                    else
                      internalerror(2012051301);
                  end;
                  { don't free before the above, because then the getintregister
                    could reallocate this register and overwrite it }
                  unget_para(paraloc^);
                  gen_alloc_regloc(list,destloc,vardef);
                  if (target_info.endian=endian_big) then
                    { paraloc^ -> high
                      paraloc^.next -> low }
                    reg64:=joinreg64(tempreg,paraloc^.register)
                  else
                    reg64:=joinreg64(paraloc^.register,tempreg);
                  cg64.a_loadmm_intreg64_reg(list,OS_F64,reg64,destloc.register);
                end
              else
{$endif not cpu64bitalu}
                begin
                  if not assigned(paraloc^.next) then
                    begin
                      unget_para(paraloc^);
                      gen_alloc_regloc(list,destloc,vardef);
                      { from register to register -> alignment is irrelevant }
                      cg.a_load_cgparaloc_anyreg(list,destloc.size,paraloc^,destloc.register,0);
                    end
                  else
                    begin
                      internalerror(200410108);
                    end;
                  { data could come in two memory locations, for now
                    we simply ignore the sanity check (FK)
                  if assigned(paraloc^.next) then
                    internalerror(200410108);
                  }
                end;
            end;
          else
            internalerror(2010052903);
        end;
      end;


    procedure gen_load_para_value(list:TAsmList);

       procedure get_para(const paraloc:TCGParaLocation);
         begin
            case paraloc.loc of
              LOC_REGISTER :
                begin
                  if getsupreg(paraloc.register)<first_int_imreg then
                    cg.getcpuregister(list,paraloc.register);
                end;
              LOC_MMREGISTER :
                begin
                  if getsupreg(paraloc.register)<first_mm_imreg then
                    cg.getcpuregister(list,paraloc.register);
                end;
              LOC_FPUREGISTER :
                begin
                  if getsupreg(paraloc.register)<first_fpu_imreg then
                    cg.getcpuregister(list,paraloc.register);
                end;
            end;
         end;


      var
        i : longint;
        currpara : tparavarsym;
        paraloc  : pcgparalocation;
      begin
        if (po_assembler in current_procinfo.procdef.procoptions) or
        { exceptfilters have a single hidden 'parentfp' parameter, which
          is handled by tcg.g_proc_entry. }
           (current_procinfo.procdef.proctypeoption=potype_exceptfilter) then
          exit;

        { Allocate registers used by parameters }
        for i:=0 to current_procinfo.procdef.paras.count-1 do
          begin
            currpara:=tparavarsym(current_procinfo.procdef.paras[i]);
            paraloc:=currpara.paraloc[calleeside].location;
            while assigned(paraloc) do
              begin
                if paraloc^.loc in [LOC_REGISTER,LOC_FPUREGISTER,LOC_MMREGISTER] then
                  get_para(paraloc^);
                paraloc:=paraloc^.next;
              end;
          end;

        { Copy parameters to local references/registers }
        for i:=0 to current_procinfo.procdef.paras.count-1 do
          begin
            currpara:=tparavarsym(current_procinfo.procdef.paras[i]);
            { don't use currpara.vardef, as this will be wrong in case of
              call-by-reference parameters (it won't contain the pointerdef) }
            gen_load_cgpara_loc(list,currpara.paraloc[calleeside].def,currpara.paraloc[calleeside],currpara.initialloc,paramanager.param_use_paraloc(currpara.paraloc[calleeside]));
            { gen_load_cgpara_loc() already allocated the initialloc
              -> don't allocate again }
            if currpara.initialloc.loc in [LOC_CREGISTER,LOC_CFPUREGISTER,LOC_CMMREGISTER] then
              begin
                gen_alloc_regvar(list,currpara,false);
                hlcg.varsym_set_localloc(list,currpara);
              end;
          end;

        { generate copies of call by value parameters, must be done before
          the initialization and body is parsed because the refcounts are
          incremented using the local copies }
        current_procinfo.procdef.parast.SymList.ForEachCall(@hlcg.g_copyvalueparas,list);
        if not(po_assembler in current_procinfo.procdef.procoptions) then
          begin
            { initialize refcounted paras, and trash others. Needed here
              instead of in gen_initialize_code, because when a reference is
              intialised or trashed while the pointer to that reference is kept
              in a regvar, we add a register move and that one again has to
              come after the parameter loading code as far as the register
              allocator is concerned }
            current_procinfo.procdef.parast.SymList.ForEachCall(@init_paras,list);
          end;
      end;


{****************************************************************************
                                Entry/Exit
****************************************************************************}

    procedure alloc_proc_symbol(pd: tprocdef);
      var
        item : TCmdStrListItem;
      begin
        item := TCmdStrListItem(pd.aliasnames.first);
        while assigned(item) do
          begin
            { The condition to use global or local symbol must match
              the code written in hlcg.gen_proc_symbol to 
              avoid change from AB_LOCAL to AB_GLOBAL, which generates
              erroneous code (at least for targets using GOT) } 
            if (cs_profile in current_settings.moduleswitches) or
               (po_global in current_procinfo.procdef.procoptions) then
              current_asmdata.DefineAsmSymbol(item.str,AB_GLOBAL,AT_FUNCTION,pd)
            else
              current_asmdata.DefineAsmSymbol(item.str,AB_LOCAL,AT_FUNCTION,pd);
           item := TCmdStrListItem(item.next);
         end;
      end;


    procedure release_proc_symbol(pd:tprocdef);
      var
        idx : longint;
        item : TCmdStrListItem;
      begin
        item:=TCmdStrListItem(pd.aliasnames.first);
        while assigned(item) do
          begin
            idx:=current_asmdata.AsmSymbolDict.findindexof(item.str);
            if idx>=0 then
              current_asmdata.AsmSymbolDict.Delete(idx);
            item:=TCmdStrListItem(item.next);
          end;
      end;


    procedure gen_proc_entry_code(list:TAsmList);
      var
        hitemp,
        lotemp, stack_frame_size : longint;
      begin
        { generate call frame marker for dwarf call frame info }
        current_asmdata.asmcfi.start_frame(list);

        { All temps are know, write offsets used for information }
        if (cs_asm_source in current_settings.globalswitches) and
           (current_procinfo.tempstart<>tg.lasttemp) then
          begin
            if tg.direction>0 then
              begin
                lotemp:=current_procinfo.tempstart;
                hitemp:=tg.lasttemp;
              end
            else
              begin
                lotemp:=tg.lasttemp;
                hitemp:=current_procinfo.tempstart;
              end;
            list.concat(Tai_comment.Create(strpnew('Temps allocated between '+std_regname(current_procinfo.framepointer)+
              tostr_with_plus(lotemp)+' and '+std_regname(current_procinfo.framepointer)+tostr_with_plus(hitemp))));
          end;

         { generate target specific proc entry code }
         stack_frame_size := current_procinfo.calc_stackframe_size;
         if (stack_frame_size <> 0) and
            (po_nostackframe in current_procinfo.procdef.procoptions) then
           message1(parser_e_nostackframe_with_locals,tostr(stack_frame_size));

         hlcg.g_proc_entry(list,stack_frame_size,(po_nostackframe in current_procinfo.procdef.procoptions));
      end;


    procedure gen_proc_exit_code(list:TAsmList);
      var
        parasize : longint;
      begin
        { c style clearstack does not need to remove parameters from the stack, only the
          return value when it was pushed by arguments }
        if current_procinfo.procdef.proccalloption in clearstack_pocalls then
          begin
            parasize:=0;
            { For safecall functions with safecall-exceptions enabled the funcret is always returned as a para
              which is considered a normal para on the c-side, so the funcret has to be pop'ed normally. }
            if not ( (current_procinfo.procdef.proccalloption=pocall_safecall) and
                     (tf_safecall_exceptions in target_info.flags) ) and
                   paramanager.ret_in_param(current_procinfo.procdef.returndef,current_procinfo.procdef) then
              inc(parasize,sizeof(pint));
          end
        else
          begin
            parasize:=current_procinfo.para_stack_size;
            { the parent frame pointer para has to be removed always by the caller in
              case of Delphi-style parent frame pointer passing }
            if (not(paramanager.use_fixed_stack) or (target_info.abi=abi_i386_dynalignedstack)) and
               (po_delphi_nested_cc in current_procinfo.procdef.procoptions) then
              dec(parasize,sizeof(pint));
          end;

        { generate target specific proc exit code }
        hlcg.g_proc_exit(list,parasize,(po_nostackframe in current_procinfo.procdef.procoptions));

        { release return registers, needed for optimizer }
        if not is_void(current_procinfo.procdef.returndef) then
          paramanager.freecgpara(list,current_procinfo.procdef.funcretloc[calleeside]);

        { end of frame marker for call frame info }
        current_asmdata.asmcfi.end_frame(list);
      end;


    procedure gen_save_used_regs(list:TAsmList);
      begin
        { Pure assembler routines need to save the registers themselves }
        if (po_assembler in current_procinfo.procdef.procoptions) then
          exit;

        cg.g_save_registers(list);
      end;


    procedure gen_restore_used_regs(list:TAsmList);
      begin
        { Pure assembler routines need to save the registers themselves }
        if (po_assembler in current_procinfo.procdef.procoptions) then
          exit;

        cg.g_restore_registers(list);
      end;


{****************************************************************************
                               Const Data
****************************************************************************}

    procedure gen_alloc_symtable(list:TAsmList;pd:tprocdef;st:TSymtable);

      var
        i       : longint;
        highsym,
        sym     : tsym;
        vs      : tabstractnormalvarsym;
        ptrdef  : tdef;
        isaddr  : boolean;
      begin
        for i:=0 to st.SymList.Count-1 do
          begin
            sym:=tsym(st.SymList[i]);
            case sym.typ of
              staticvarsym :
                begin
                  vs:=tabstractnormalvarsym(sym);
                  { The code in loadnode.pass_generatecode will create the
                    LOC_REFERENCE instead for all none register variables. This is
                    required because we can't store an asmsymbol in the localloc because
                    the asmsymbol is invalid after an unit is compiled. This gives
                    problems when this procedure is inlined in another unit (PFV) }
                  if vs.is_regvar(false) then
                    begin
                      vs.initialloc.loc:=tvarregable2tcgloc[vs.varregable];
                      vs.initialloc.size:=def_cgsize(vs.vardef);
                      gen_alloc_regvar(list,vs,true);
                      hlcg.varsym_set_localloc(list,vs);
                    end;
                end;
              paravarsym :
                begin
                  vs:=tabstractnormalvarsym(sym);
                  { Parameters passed to assembler procedures need to be kept
                    in the original location }
                  if (po_assembler in pd.procoptions) then
                    tparavarsym(vs).paraloc[calleeside].get_location(vs.initialloc)
                  { exception filters receive their frame pointer as a parameter }
                  else if (pd.proctypeoption=potype_exceptfilter) and
                    (vo_is_parentfp in vs.varoptions) then
                    begin
                      location_reset(vs.initialloc,LOC_REGISTER,OS_ADDR);
                      vs.initialloc.register:=NR_FRAME_POINTER_REG;
                    end
                  else
                    begin
                      { if an open array is used, also its high parameter is used,
                        since the hidden high parameters are inserted after the corresponding symbols,
                        we can increase the ref. count here }
                      if is_open_array(vs.vardef) or is_array_of_const(vs.vardef) then
                        begin
                          highsym:=get_high_value_sym(tparavarsym(vs));
                          if assigned(highsym) then
                            inc(highsym.refs);
                        end;

                      isaddr:=paramanager.push_addr_param(vs.varspez,vs.vardef,pd.proccalloption);
                      if isaddr then
                        vs.initialloc.size:=def_cgsize(voidpointertype)
                      else
                        vs.initialloc.size:=def_cgsize(vs.vardef);

                      if vs.is_regvar(isaddr) then
                        vs.initialloc.loc:=tvarregable2tcgloc[vs.varregable]
                      else
                        begin
                          vs.initialloc.loc:=LOC_REFERENCE;
                          { Reuse the parameter location for values to are at a single location on the stack }
                          if paramanager.param_use_paraloc(tparavarsym(vs).paraloc[calleeside]) then
                            begin
                              hlcg.paravarsym_set_initialloc_to_paraloc(tparavarsym(vs));
                            end
                          else
                            begin
                              if isaddr then
                                begin
                                  ptrdef:=cpointerdef.getreusable(vs.vardef);
                                  tg.GetLocal(list,ptrdef.size,ptrdef,vs.initialloc.reference)
                                end
                              else
                                tg.GetLocal(list,vs.getsize,tparavarsym(vs).paraloc[calleeside].alignment,vs.vardef,vs.initialloc.reference);
                            end;
                        end;
                    end;
                  hlcg.varsym_set_localloc(list,vs);
                end;
              localvarsym :
                begin
                  vs:=tabstractnormalvarsym(sym);
                  vs.initialloc.size:=def_cgsize(vs.vardef);
                  if ([po_assembler,po_nostackframe] * pd.procoptions = [po_assembler,po_nostackframe]) and
                     (vo_is_funcret in vs.varoptions) then
                    begin
                      paramanager.create_funcretloc_info(pd,calleeside);
                      if assigned(pd.funcretloc[calleeside].location^.next) then
                        begin
                          { can't replace references to "result" with a complex
                            location expression inside assembler code }
                          location_reset(vs.initialloc,LOC_INVALID,OS_NO);
                        end
                      else
                        pd.funcretloc[calleeside].get_location(vs.initialloc);
                    end
                  else if (m_delphi in current_settings.modeswitches) and
                     (po_assembler in pd.procoptions) and
                     (vo_is_funcret in vs.varoptions) and
                     (vs.refs=0) then
                    begin
                      { not referenced, so don't allocate. Use dummy to }
                      { avoid ie's later on because of LOC_INVALID      }
                      vs.initialloc.loc:=LOC_REGISTER;
                      vs.initialloc.size:=OS_INT;
                      vs.initialloc.register:=NR_FUNCTION_RESULT_REG;
                    end
                  else if vs.is_regvar(false) then
                    begin
                      vs.initialloc.loc:=tvarregable2tcgloc[vs.varregable];
                      gen_alloc_regvar(list,vs,true);
                    end
                  else
                    begin
                      vs.initialloc.loc:=LOC_REFERENCE;
                      tg.GetLocal(list,vs.getsize,vs.vardef,vs.initialloc.reference);
                    end;
                  hlcg.varsym_set_localloc(list,vs);
                end;
            end;
          end;
      end;


    procedure add_regvars(var rv: tusedregvars; const location: tlocation);
      begin
        case location.loc of
          LOC_CREGISTER:
{$if defined(cpu64bitalu)}
            if location.size in [OS_128,OS_S128] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register128.reglo));
                rv.intregvars.addnodup(getsupreg(location.register128.reghi));
              end
            else
{$elseif defined(cpu32bitalu)}
            if location.size in [OS_64,OS_S64] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register64.reglo));
                rv.intregvars.addnodup(getsupreg(location.register64.reghi));
              end
            else
{$elseif defined(cpu16bitalu)}
            if location.size in [OS_64,OS_S64] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register64.reglo));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register64.reglo)));
                rv.intregvars.addnodup(getsupreg(location.register64.reghi));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register64.reghi)));
              end
            else
            if location.size in [OS_32,OS_S32] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register)));
              end
            else
{$elseif defined(cpu8bitalu)}
            if location.size in [OS_64,OS_S64] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register64.reglo));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register64.reglo)));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(location.register64.reglo))));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(location.register64.reglo)))));
                rv.intregvars.addnodup(getsupreg(location.register64.reghi));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register64.reghi)));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(location.register64.reghi))));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(location.register64.reghi)))));
              end
            else
            if location.size in [OS_32,OS_S32] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register)));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(location.register))));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(location.register)))));
              end
            else
            if location.size in [OS_16,OS_S16] then
              begin
                rv.intregvars.addnodup(getsupreg(location.register));
                rv.intregvars.addnodup(getsupreg(cg.GetNextReg(location.register)));
              end
            else
{$endif}
              if getregtype(location.register)=R_INTREGISTER then
                rv.intregvars.addnodup(getsupreg(location.register))
              else
                rv.addrregvars.addnodup(getsupreg(location.register));
          LOC_CFPUREGISTER:
            rv.fpuregvars.addnodup(getsupreg(location.register));
          LOC_CMMREGISTER:
            rv.mmregvars.addnodup(getsupreg(location.register));
        end;
      end;


    function do_get_used_regvars(var n: tnode; arg: pointer): foreachnoderesult;
      var
        rv: pusedregvars absolute arg;
      begin
        case (n.nodetype) of
          temprefn:
            { We only have to synchronise a tempnode before a loop if it is }
            { not created inside the loop, and only synchronise after the   }
            { loop if it's not destroyed inside the loop. If it's created   }
            { before the loop and not yet destroyed, then before the loop   }
            { is secondpassed tempinfo^.valid will be true, and we get the  }
            { correct registers. If it's not destroyed inside the loop,     }
            { then after the loop has been secondpassed tempinfo^.valid     }
            { be true and we also get the right registers. In other cases,  }
            { tempinfo^.valid will be false and so we do not add            }
            { unnecessary registers. This way, we don't have to look at     }
            { tempcreate and tempdestroy nodes to get this info (JM)        }
            if (ti_valid in ttemprefnode(n).tempflags) then
              add_regvars(rv^,ttemprefnode(n).tempinfo^.location);
          loadn:
            if (tloadnode(n).symtableentry.typ in [staticvarsym,localvarsym,paravarsym]) then
              add_regvars(rv^,tabstractnormalvarsym(tloadnode(n).symtableentry).localloc);
          vecn:
            { range checks sometimes need the high parameter }
            if (cs_check_range in current_settings.localswitches) and
               (is_open_array(tvecnode(n).left.resultdef) or
                is_array_of_const(tvecnode(n).left.resultdef)) and
               not(current_procinfo.procdef.proccalloption in cdecl_pocalls) then
              add_regvars(rv^,tabstractnormalvarsym(get_high_value_sym(tparavarsym(tloadnode(tvecnode(n).left).symtableentry))).localloc)

        end;
        result := fen_true;
      end;


    procedure get_used_regvars(n: tnode; var rv: tusedregvars);
      begin
        foreachnodestatic(n,@do_get_used_regvars,@rv);
      end;

(*
    See comments at declaration of pusedregvarscommon

    function do_get_used_regvars_common(var n: tnode; arg: pointer): foreachnoderesult;
      var
        rv: pusedregvarscommon absolute arg;
      begin
        if (n.nodetype = loadn) and
           (tloadnode(n).symtableentry.typ in [staticvarsym,localvarsym,paravarsym]) then
          with tabstractnormalvarsym(tloadnode(n).symtableentry).localloc do
            case loc of
              LOC_CREGISTER:
                  { if not yet encountered in this node tree }
                if (rv^.myregvars.intregvars.addnodup(getsupreg(register))) and
                  { but nevertheless already encountered somewhere }
                   not(rv^.allregvars.intregvars.addnodup(getsupreg(register))) then
                  { then it's a regvar used in two or more node trees }
                  rv^.commonregvars.intregvars.addnodup(getsupreg(register));
              LOC_CFPUREGISTER:
                if (rv^.myregvars.intregvars.addnodup(getsupreg(register))) and
                   not(rv^.allregvars.intregvars.addnodup(getsupreg(register))) then
                  rv^.commonregvars.intregvars.addnodup(getsupreg(register));
              LOC_CMMREGISTER:
                if (rv^.myregvars.intregvars.addnodup(getsupreg(register))) and
                   not(rv^.allregvars.intregvars.addnodup(getsupreg(register))) then
                  rv^.commonregvars.intregvars.addnodup(getsupreg(register));
            end;
        result := fen_true;
      end;


    procedure get_used_regvars_common(n: tnode; var rv: tusedregvarscommon);
      begin
        rv.myregvars.intregvars.clear;
        rv.myregvars.fpuregvars.clear;
        rv.myregvars.mmregvars.clear;
        foreachnodestatic(n,@do_get_used_regvars_common,@rv);
      end;
*)

    procedure gen_sync_regvars(list:TAsmList; var rv: tusedregvars);
      var
        count: longint;
      begin
        for count := 1 to rv.intregvars.length do
          cg.a_reg_sync(list,newreg(R_INTREGISTER,rv.intregvars.readidx(count-1),R_SUBWHOLE));
        for count := 1 to rv.addrregvars.length do
          cg.a_reg_sync(list,newreg(R_ADDRESSREGISTER,rv.addrregvars.readidx(count-1),R_SUBWHOLE));
        for count := 1 to rv.fpuregvars.length do
          cg.a_reg_sync(list,newreg(R_FPUREGISTER,rv.fpuregvars.readidx(count-1),R_SUBWHOLE));
        for count := 1 to rv.mmregvars.length do
          cg.a_reg_sync(list,newreg(R_MMREGISTER,rv.mmregvars.readidx(count-1),R_SUBWHOLE));
      end;


    procedure gen_free_symtable(list:TAsmList;st:TSymtable);
      var
        i   : longint;
        sym : tsym;
      begin
        for i:=0 to st.SymList.Count-1 do
          begin
            sym:=tsym(st.SymList[i]);
            if (sym.typ in [staticvarsym,localvarsym,paravarsym]) then
              begin
                with tabstractnormalvarsym(sym) do
                  begin
                    { Note: We need to keep the data available in memory
                      for the sub procedures that can access local data
                      in the parent procedures }
                    case localloc.loc of
                      LOC_CREGISTER :
                        if (pi_has_label in current_procinfo.flags) then
{$if defined(cpu64bitalu)}
                          if def_cgsize(vardef) in [OS_128,OS_S128] then
                            begin
                              cg.a_reg_sync(list,localloc.register128.reglo);
                              cg.a_reg_sync(list,localloc.register128.reghi);
                            end
                          else
{$elseif defined(cpu32bitalu)}
                          if def_cgsize(vardef) in [OS_64,OS_S64] then
                            begin
                              cg.a_reg_sync(list,localloc.register64.reglo);
                              cg.a_reg_sync(list,localloc.register64.reghi);
                            end
                          else
{$elseif defined(cpu16bitalu)}
                          if def_cgsize(vardef) in [OS_64,OS_S64] then
                            begin
                              cg.a_reg_sync(list,localloc.register64.reglo);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register64.reglo));
                              cg.a_reg_sync(list,localloc.register64.reghi);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register64.reghi));
                            end
                          else
                          if def_cgsize(vardef) in [OS_32,OS_S32] then
                            begin
                              cg.a_reg_sync(list,localloc.register);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register));
                            end
                          else
{$elseif defined(cpu8bitalu)}
                          if def_cgsize(vardef) in [OS_64,OS_S64] then
                            begin
                              cg.a_reg_sync(list,localloc.register64.reglo);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register64.reglo));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(localloc.register64.reglo)));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(localloc.register64.reglo))));
                              cg.a_reg_sync(list,localloc.register64.reghi);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register64.reghi));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(localloc.register64.reghi)));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(localloc.register64.reghi))));
                            end
                          else
                          if def_cgsize(vardef) in [OS_32,OS_S32] then
                            begin
                              cg.a_reg_sync(list,localloc.register);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(localloc.register)));
                              cg.a_reg_sync(list,cg.GetNextReg(cg.GetNextReg(cg.GetNextReg(localloc.register))));
                            end
                          else
                          if def_cgsize(vardef) in [OS_16,OS_S16] then
                            begin
                              cg.a_reg_sync(list,localloc.register);
                              cg.a_reg_sync(list,cg.GetNextReg(localloc.register));
                            end
                          else
{$endif}
                            cg.a_reg_sync(list,localloc.register);
                      LOC_CFPUREGISTER,
                      LOC_CMMREGISTER:
                        if (pi_has_label in current_procinfo.flags) then
                          cg.a_reg_sync(list,localloc.register);
                      LOC_REFERENCE :
                        begin
                          if typ in [localvarsym,paravarsym] then
                            tg.Ungetlocal(list,localloc.reference);
                        end;
                    end;
                  end;
              end;
          end;
      end;


    function getprocalign : shortint;
      begin
        { gprof uses 16 byte granularity }
        if (cs_profile in current_settings.moduleswitches) then
          result:=16
        else
         result:=current_settings.alignment.procalign;
      end;


    procedure gen_load_frame_for_exceptfilter(list : TAsmList);
      var
        para: tparavarsym;
      begin
        para:=tparavarsym(current_procinfo.procdef.paras[0]);
        if not (vo_is_parentfp in para.varoptions) then
          InternalError(201201142);
        if (para.paraloc[calleeside].location^.loc<>LOC_REGISTER) or
          (para.paraloc[calleeside].location^.next<>nil) then
          InternalError(201201143);
        cg.a_load_reg_reg(list,OS_ADDR,OS_ADDR,para.paraloc[calleeside].location^.register,
          NR_FRAME_POINTER_REG);
      end;

end.

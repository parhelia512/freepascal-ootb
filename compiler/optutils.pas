{
    Helper routines for the optimizer

    Copyright (c) 2007 by Florian Klaempfl

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
unit optutils;

{$i fpcdefs.inc}

  interface

    uses
      cclasses,
      node,
      globtype;

    type
      { this implementation should be really improved,
        its purpose is to find equal nodes }
      TIndexedNodeSet = class(TFPList)
        function Add(node : tnode) : boolean;
        function Includes(node : tnode) : tnode;
        function Remove(node : tnode) : boolean;
      end;

    procedure SetNodeSucessors(p,last : tnode);
    procedure PrintDFAInfo(var f : text;p : tnode);
    procedure PrintIndexedNodeSet(var f : text;s : TIndexedNodeSet);
    { determines the optinfo.defsum field for the given node
      this field contains a sum of all expressions defined by
      all child expressions reachable through p
    }
    procedure CalcDefSum(p : tnode);

    { calculates/estimates the field execution weight of optinfo }
    procedure CalcExecutionWeights(p : tnode;Initial : longint = 100);

    { returns true, if n is a valid node and has life info }
    function has_life_info(n : tnode) : boolean;

  implementation

    uses
      cutils,
      verbose,
      optbase,
      ncal,nbas,nflw,nutils,nset,ncon;

    function TIndexedNodeSet.Add(node : tnode) : boolean;
      var
        i : Integer;
        p : tnode;
      begin
        node.allocoptinfo;
        p:=Includes(node);
        if assigned(p) then
          begin
            result:=false;
            node.optinfo^.index:=p.optinfo^.index;
          end
        else
          begin
            i:=inherited Add(node);
            node.optinfo^.index:=i;
            result:=true;
          end
      end;


    function TIndexedNodeSet.Includes(node : tnode) : tnode;
      var
        i : longint;
      begin
        for i:=0 to Count-1 do
          if tnode(List^[i]).isequal(node) then
            begin
              result:=tnode(List^[i]);
              exit;
            end;
        result:=nil;
      end;


    function TIndexedNodeSet.Remove(node : tnode) : boolean;
      var
        p : tnode;
      begin
        result:=false;
        p:=Includes(node);
        if assigned(p) then
          begin
            if inherited Remove(p)<>-1 then
              result:=true;
          end;
      end;


    procedure PrintIndexedNodeSet(var f : text;s : TIndexedNodeSet);
      var
        i : integer;
      begin
        for i:=0 to s.count-1 do
          begin
            writeln(f,'=============================== Node ',i,' ===============================');
            printnode(f,tnode(s[i]));
            writeln(f);
          end;
      end;


    function PrintNodeDFA(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        if assigned(n.optinfo) and ((n.optinfo^.life<>nil) or (n.optinfo^.use<>nil) or (n.optinfo^.def<>nil)) then
          begin
            write(text(arg^),nodetype2str[n.nodetype],'(',n.fileinfo.line,',',n.fileinfo.column,') Life: ');
            PrintDFASet(text(arg^),n.optinfo^.life);
            write(text(arg^),' Def: ');
            PrintDFASet(text(arg^),n.optinfo^.def);
            write(text(arg^),' Use: ');
            PrintDFASet(text(arg^),n.optinfo^.use);
            if assigned(n.successor) then
              write(text(arg^),' Successor: ',nodetype2str[n.successor.nodetype],'(',n.successor.fileinfo.line,',',n.successor.fileinfo.column,')')
            else
              write(text(arg^),' Successor: nil');
            write(text(arg^),' DefSum: ');
            PrintDFASet(text(arg^),n.optinfo^.defsum);
            writeln(text(arg^));
          end;
        result:=fen_false;
      end;


    procedure PrintDFAInfo(var f : text;p : tnode);
      begin
        foreachnodestatic(pm_postprocess,p,@PrintNodeDFA,@f);
      end;


    procedure SetNodeSucessors(p,last : tnode);
      var
        Continuestack : TFPList;
        Breakstack : TFPList;
      { sets the successor nodes of a node tree block
        returns the first node of the tree if it's a controll flow node }
      function DoSet(p : tnode;succ : tnode) : tnode;
        var
          hp1,hp2 : tnode;
          i : longint;
        begin
          result:=nil;
          if p=nil then
            exit;
          case p.nodetype of
            statementn:
              begin
                hp1:=p;
                result:=p;
                while assigned(hp1) do
                  begin
                    { does another statement follow? }
                    if assigned(tstatementnode(hp1).next) then
                      begin
                        hp2:=DoSet(tstatementnode(hp1).statement,tstatementnode(hp1).next);
                        if assigned(hp2) then
                          tstatementnode(hp1).successor:=hp2
                        else
                          tstatementnode(hp1).successor:=tstatementnode(hp1).next;
                      end
                    else
                      begin
                        hp2:=DoSet(tstatementnode(hp1).statement,succ);
                        if assigned(hp2) then
                          tstatementnode(hp1).successor:=hp2
                        else
                          tstatementnode(hp1).successor:=succ;
                      end;
                    hp1:=tstatementnode(hp1).next;
                  end;
              end;
            blockn:
              begin
                result:=p;
                DoSet(tblocknode(p).statements,succ);
                if assigned(tblocknode(p).statements) then
                  p.successor:=tblocknode(p).statements
                else
                  p.successor:=succ;
              end;
            forn:
              begin
                Breakstack.Add(succ);
                Continuestack.Add(p);
                result:=p;
                { the successor of the last node of the for body is the dummy loop iteration node
                  it allows the dfa to inject needed life information into the loop }
                tfornode(p).loopiteration:=cnothingnode.create;

                DoSet(tfornode(p).t2,tfornode(p).loopiteration);
                p.successor:=succ;
                Breakstack.Delete(Breakstack.Count-1);
                Continuestack.Delete(Continuestack.Count-1);
              end;
            breakn:
              begin
                result:=p;
                p.successor:=tnode(Breakstack.Last);
              end;
            continuen:
              begin
                result:=p;
                p.successor:=tnode(Continuestack.Last);
              end;
            whilerepeatn:
              begin
                Breakstack.Add(succ);
                Continuestack.Add(p);
                result:=p;
                { the successor of the last node of the while/repeat body is the while node itself }
                DoSet(twhilerepeatnode(p).right,p);

                p.successor:=succ;

                { special case: we do not do a dyn. dfa, but we should handle endless loops }
                if is_constboolnode(twhilerepeatnode(p).left) then
                  begin
                    if ((lnf_testatbegin in twhilerepeatnode(p).loopflags) and
                      getbooleanvalue(twhilerepeatnode(p).left)) or (not(lnf_testatbegin in twhilerepeatnode(p).loopflags) and
                      not(getbooleanvalue(twhilerepeatnode(p).left))) then
                      p.successor:=nil;
                  end;

                Breakstack.Delete(Breakstack.Count-1);
                Continuestack.Delete(Continuestack.Count-1);
              end;
            ifn:
              begin
                result:=p;
                DoSet(tifnode(p).right,succ);
                DoSet(tifnode(p).t1,succ);
                p.successor:=succ;
              end;
            labeln:
              begin
                result:=p;
                if assigned(tlabelnode(p).left) then
                  begin
                    DoSet(tlabelnode(p).left,succ);
                    p.successor:=tlabelnode(p).left;
                  end
                else
                  p.successor:=succ;
              end;
            assignn:
              begin
                result:=p;
                p.successor:=succ;
              end;
            goton:
              begin
                result:=p;
                if not(assigned(tgotonode(p).labelnode)) then
                  internalerror(2007050701);
                p.successor:=tgotonode(p).labelnode;
              end;
            exitn:
              begin
                result:=p;
                p.successor:=nil;
              end;
            casen:
              begin
                result:=p;
                DoSet(tcasenode(p).elseblock,succ);
                for i:=0 to tcasenode(p).blocks.count-1 do
                  DoSet(pcaseblock(tcasenode(p).blocks[i])^.statement,succ);
                p.successor:=succ;
              end;
            calln:
              begin
                { not sure if this is enough (FK) }
                result:=p;
                if cnf_call_never_returns in tcallnode(p).callnodeflags then
                  p.successor:=nil
                else
                  p.successor:=succ;
              end;
            inlinen:
              begin
                { not sure if this is enough (FK) }
                result:=p;
                p.successor:=succ;
              end;
            loadn,
            tempcreaten,
            tempdeleten,
            nothingn:
               begin
                result:=p;
                p.successor:=succ;
              end;
            raisen:
              begin
                result:=p;
                { raise never returns }
                p.successor:=nil;
              end;
            tryexceptn,
            tryfinallyn,
            onn:
              internalerror(2007050501);
          end;
        end;

      begin
        Breakstack:=TFPList.Create;
        Continuestack:=TFPList.Create;
        DoSet(p,last);
        Continuestack.Free;
        Breakstack.Free;
      end;

    var
      sum : TDFASet;

    function adddef(var n: tnode; arg: pointer): foreachnoderesult;
      begin
        if assigned(n.optinfo) then
          DFASetIncludeSet(sum,n.optinfo^.def);
        Result:=fen_false;
      end;


    procedure CalcDefSum(p : tnode);
      begin
        p.allocoptinfo;
        if not assigned(p.optinfo^.defsum) then
          begin
            sum:=nil;
            foreachnodestatic(pm_postprocess,p,@adddef,nil);
            p.optinfo^.defsum:=sum;
          end;
      end;


    function SetExecutionWeight(var n: tnode; arg: pointer): foreachnoderesult;
      var
        Weight : longint;
        i : Integer;
      begin
        Result:=fen_false;
        n.allocoptinfo;
        Weight:=max(plongint(arg)^,1);
        case n.nodetype of
          casen:
            begin
              CalcExecutionWeights(tcasenode(n).left,Weight);
              for i:=0 to tcasenode(n).blocks.count-1 do
                CalcExecutionWeights(pcaseblock(tcasenode(n).blocks[i])^.statement,max(1,Weight div case_count_labels(tcasenode(n).labels)));

              CalcExecutionWeights(tcasenode(n).elseblock,max(1,Weight div case_count_labels(tcasenode(n).labels)));
              Result:=fen_norecurse_false;
            end;
          whilerepeatn:
            begin
              CalcExecutionWeights(twhilerepeatnode(n).right,max(Weight,1)*8);
              CalcExecutionWeights(twhilerepeatnode(n).left,max(Weight,1)*8);
              Result:=fen_norecurse_false;
            end;
          ifn:
            begin
              CalcExecutionWeights(tifnode(n).left,Weight);
              CalcExecutionWeights(tifnode(n).right,max(Weight div 2,1));
              CalcExecutionWeights(tifnode(n).t1,max(Weight div 2,1));
              Result:=fen_norecurse_false;
            end;
          else
            n.optinfo^.executionweight:=weight;
        end;
      end;


    procedure CalcExecutionWeights(p : tnode;Initial : longint = 100);
      begin
        if assigned(p) then
          foreachnodestatic(pm_postprocess,p,@SetExecutionWeight,Pointer(@Initial));
      end;


    function has_life_info(n : tnode) : boolean;
      begin
        result:=assigned(n) and assigned(n.optinfo) and
          assigned(n.optinfo^.life);
      end;

end.


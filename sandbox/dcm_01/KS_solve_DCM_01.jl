"""
Solves Kohn-Sham problem using direct constrained minimization (DCM) as described
by Prof. Chao Yang.
"""
function KS_solve_DCM_01!(
    Ham::Hamiltonian;
    NiterMax = 100, startingwfc=:random,
    MaxInnerSCF=3,
    verbose=true,
    print_final_ebands=false, print_final_energies=true,
    savewfc=false, etot_conv_thr=1e-6
)


    pw = Ham.pw
    Ngw = pw.gvecw.Ngw
    Ns = pw.Ns
    Npoints = prod(Ns)
    CellVolume = pw.CellVolume
    ΔV = CellVolume/Npoints

    electrons = Ham.electrons
    Nelectrons = electrons.Nelectrons
    Focc = electrons.Focc
    Nocc = electrons.Nstates_occ
    Nstates = electrons.Nstates
    
    Nkpt = Ham.pw.gvecw.kpoints.Nkpt
    Nspin = electrons.Nspin

    Nkspin = Nkpt*Nspin

    psiks = BlochWavefunc(undef,Nkspin)

    #
    # Initial wave function
    #
    if startingwfc == :read
        psiks = read_psiks( Ham )
    else
        # generate random BlochWavefunc
        psiks = rand_BlochWavefunc( Ham )
    end

    #
    # Calculated electron density from this wave function and update Hamiltonian
    #
    Rhoe = zeros(Float64,Npoints,Nspin)

    calc_rhoe!( Ham, psiks, Rhoe )

    update!(Ham, Rhoe)

    Rhoe_old = copy(Rhoe)

    evals = zeros(Float64,Nstates,Nkspin)

    # calculate E_NN
    Ham.energies.NN = calc_E_NN( Ham.atoms )

    # calculate PspCore energy
    Ham.energies.PspCore = calc_PspCore_ene( Ham.atoms, Ham.pspots )
    
    # Starting eigenvalues and psi
    for ispin = 1:Nspin
    for ik = 1:Nkpt
        Ham.ik = ik
        Ham.ispin = ispin
        ikspin = ik + (ispin - 1)*Nkpt
        evals[:,ikspin], psiks[ikspin] =
        diag_LOBPCG( Ham, psiks[ikspin], verbose_last=false, NiterMax=10 )
    end
    end

    Ham.energies = calc_energies( Ham, psiks )
    
    Etot = sum(Ham.energies)
    Etot_old = Etot
    diffE = 1.0 # any number that is not 0

    # subspace
    Y = BlochWavefunc(undef,Nkspin)
    R = BlochWavefunc(undef,Nkspin)
    P = BlochWavefunc(undef,Nkspin)

    G = Array{Array{ComplexF64,2},1}(undef,Nkspin)
    T = Array{Array{Float64,2},1}(undef,Nkspin)
    B = Array{Array{Float64,2},1}(undef,Nkspin)
    A = Array{Array{Float64,2},1}(undef,Nkspin)
    C = Array{Array{Float64,2},1}(undef,Nkspin)
    for ispin = 1:Nspin
    for ik = 1:Nkpt
        ikspin = ik + (ispin - 1)*Nkpt
        Y[ikspin] = zeros( ComplexF64, Ngw[ik], 3*Nstates )
        R[ikspin] = zeros( ComplexF64, Ngw[ik], Nstates )
        P[ikspin] = zeros( ComplexF64, Ngw[ik], Nstates )
        G[ikspin] = zeros( ComplexF64, 3*Nstates, 3*Nstates )
        T[ikspin] = zeros( Float64, 3*Nstates, 3*Nstates )
        B[ikspin] = zeros( Float64, 3*Nstates, 3*Nstates )
        A[ikspin] = zeros( Float64, 3*Nstates, 3*Nstates )
        C[ikspin] = zeros( Float64, 3*Nstates, 3*Nstates )        
    end
    end

    D = zeros(Float64,3*Nstates,Nkspin)  # array for saving eigenvalues of subspace problem

    set1 = 1:Nstates
    set2 = Nstates+1:2*Nstates
    set3 = 2*Nstates+1:3*Nstates
    set4 = Nstates+1:3*Nstates
    set5 = 1:2*Nstates

    Nconverges = 0

    for iter = 1:NiterMax
        
        @printf("DCM iter: %3d\n", iter)

        for ispin = 1:Nspin, ik = 1:Nkpt
            Ham.ik = ik
            Ham.ispin = ispin
            ikspin = ik + (ispin - 1)*Nkpt
            #
            Hpsi = op_H( Ham, psiks[ikspin] )
            #
            psiHpsi = psiks[ikspin]' * Hpsi
            psiHpsi = 0.5*( psiHpsi + psiHpsi' )
            # Calculate residual
            R[ikspin] = Hpsi - psiks[ikspin]*psiHpsi
            R[ikspin] = Kprec( ik, pw, R[ikspin] )
            # Construct subspace
            Y[ikspin][:,set1] = psiks[ikspin]
            Y[ikspin][:,set2] = R[ikspin]
            #
            if iter > 1
                Y[ikspin][:,set3] = P[ikspin]
            end
            
            #
            # Project kinetic and ionic potential
            #
            if iter > 1
                KY = op_K( Ham, Y[ikspin] ) + op_V_Ps_loc( Ham, Y[ikspin] )
                T[ikspin] = real(Y[ikspin]'*KY)
                B[ikspin] = real(Y[ikspin]'*Y[ikspin])
                B[ikspin] = 0.5*( B[ikspin] + B[ikspin]' )
            else
                # only set5=1:2*Nstates is active for iter=1
                KY = op_K( Ham, Y[ikspin][:,set5] ) + op_V_Ps_loc( Ham, Y[ikspin][:,set5] )
                T[ikspin][set5,set5] = real(Y[ikspin][:,set5]'*KY)
                bb = real(Y[ikspin][set5,set5]'*Y[ikspin][set5,set5])
                B[ikspin][set5,set5] = 0.5*( bb + bb' )
            end

            if iter > 1
                G[ikspin] = Matrix(1.0I, 3*Nstates, 3*Nstates) #eye(3*Nstates)
            else
                G[ikspin] = Matrix(1.0I, 2*Nstates, 2*Nstates)
            end
        
        end # ikspin

        Rhoe_old = copy(Ham.rhoe)

        Etot_innerscf = 0.0
        Etot_innerscf_old = 0.0
        dEtot_innerscf = 1.0

        for iterscf = 1:MaxInnerSCF
            
            for ispin = 1:Nspin, ik = 1:Nkpt
                #
                Ham.ik = ik
                Ham.ispin = ispin
                ikspin = ik + (ispin - 1)*Nkpt
                #
                V_loc = Ham.potentials.Hartree + Ham.potentials.XC[:,ispin]
                #
                if iter > 1
                    yy = Y[ikspin]
                else
                    yy = Y[ikspin][:,set5]
                end
                #
                if Ham.pspotNL.NbetaNL > 0
                    VY = op_V_Ps_nloc( Ham, yy ) + op_V_loc( ik, pw, V_loc, yy )
                else
                    VY = op_V_loc( ik, pw, V_loc, yy )
                end
                #
                if iter > 1
                    A[ikspin] = real( T[ikspin] + yy'*VY )
                    A[ikspin] = 0.5*( A[ikspin] + A[ikspin]' )
                else
                    aa = real( T[ikspin][set5,set5] + yy'*VY )
                    A[ikspin] = 0.5*( aa + aa' )
                end
                #
                if iter > 1
                    BG = B[ikspin]*G[ikspin][:,1:Nocc]
                    C[ikspin] = real( BG*BG' )
                    C[ikspin] = 0.5*( C[ikspin] + C[ikspin]' )
                else
                    BG = B[ikspin][set5,set5]*G[ikspin][set5,1:Nocc]
                    cc = real( BG*BG' )
                    C[ikspin][set5,set5] = 0.5*( cc + cc' )
                end
                #
                if iter > 1
                    D[:,ikspin], G[ikspin] = eigen( A[ikspin], B[ikspin] )
                else
                    D[set5,ikspin], G[ikspin][set5,set5] =
                    eigen( A[ikspin][set5,set5], B[ikspin][set5,set5] )
                end
                #
                # update wavefunction
                if iter > 1
                    psiks[ikspin] = Y[ikspin]*G[ikspin][:,set1]
                    ortho_sqrt!(psiks[ikspin])  # is this necessary ?
                else
                    psiks[ikspin] = Y[ikspin][:,set5]*G[ikspin][set5,set1]
                    ortho_sqrt!(psiks[ikspin])
                end

            end # ispin, ik

            calc_rhoe!( Ham, psiks, Rhoe )

            # mix rhoe
            Rhoe = 0.1*Rhoe + 0.9*Rhoe_old
            #for rho in Rhoe
            #    if rho < eps() rho = 0.0 end
            #end

            # update Hartree and XC potential
            update!( Ham, Rhoe )

            Rhoe_old = copy(Rhoe)

            # Calculate energies once again
            Ham.energies = calc_energies( Ham, psiks )
            Etot_innerscf = sum(Ham.energies)
            diffE = -(Etot_innerscf - Etot_innerscf_old)

            @printf("innerSCF: %5d %18.10f %18.10e", iterscf, Etot_innerscf, diffE)
            # positive value of diffE is taken as reducing
            if diffE < 0.0
                @printf(" : Energy is not reducing !\n")
            else
                @printf("\n")
            end

            if abs(diffE) < etot_conv_thr*10
                println("Breaking out from innerSCF")
                break
            end

            Etot_innerscf_old = Etot_innerscf
            
        end

        Etot = Etot_innerscf

        @printf("DCM: %5d %18.10f %18.10e\n", iter, Etot, diffE)

        if abs(diffE) < etot_conv_thr
            Nconverges = Nconverges + 1
        else
            Nconverges = 0
        end

        if Nconverges >= 2
            if verbose
                @printf("\nDCM is converged in iter: %d , diffE = %10.7e\n", iter, diffE)
            end
            break
        end

        Etot_old = Etot

        # No need to update potential, it is already updated in inner SCF loop
        for ispin = 1:Nspin, ik = 1:Nkpt
            ikspin = ik + (ispin - 1)*Nkpt
            if iter > 1
                P[ikspin] = Y[ikspin][:,set4]*G[ikspin][set4,set1]
            else
                P[ikspin] = Y[ikspin][:,set2]*G[ikspin][set2,set1]
            end
        end

        flush(stdout)
    end  # end of DCM iteration
    
    Ham.electrons.ebands = evals[:,:]

    if verbose && print_final_ebands
        @printf("\n")
        @printf("----------------------------\n")
        @printf("Final Kohn-Sham eigenvalues:\n")
        @printf("----------------------------\n")
        @printf("\n")
        print_ebands(Ham.electrons, Ham.pw.gvecw.kpoints)
    end

    if verbose && print_final_energies
        @printf("\n")
        @printf("-------------------------\n")
        @printf("Final Kohn-Sham energies:\n")
        @printf("-------------------------\n")
        @printf("\n")
        println(Ham.energies)
    end

    if savewfc
        for ikspin = 1:Nkpt*Nspin
            wfc_file = open("WFC_ikspin_"*string(ikspin)*".data","w")
            write( wfc_file, psiks[ikspin] )
            close( wfc_file )
        end
    end

    return
end


/*************************************************************
 * 
 *    kpp_integrate_cuda_prototype.cu
 *    Prototype file for kpp CUDA kernel
 *
 *    Copyright 2016 The Cyprus Institute 
 *
 *    Developers: Michail Alvanos - m.alvanos@cyi.ac.cy
 *                Giannis Ashiotis
 *                Theodoros Christoudias - christoudias@cyi.ac.cy
 *
 ********************************************************************/

#include <stdio.h>
#include <unistd.h>
#include "cuda.h"

=#=#=#=#=#=#=#=#=#=#=defines_vars_2=#=#=#=#=#=#=#=#=#=#=

#define BLOCKSIZE 64

#define MAX_VL_GLO 12288 /* elements that will pass in each call */

#define REDUCTION_SIZE_1 64
#define REDUCTION_SIZE_2 32

=#=#=#=#=#=#=#=#=#=#=defines_vars_1=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=defines_ind_1=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=defines_ind_2=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=defines_ind_3=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=defines_ind_4=#=#=#=#=#=#=#=#=#=#=

#define ifun 0
#define ijac 1
#define istp 2
#define iacc 3
#define irej 4
#define idec 5
#define isol 6
#define isng 7
#define itexit 0
#define ihexit 1

#define ZERO 0.0
#define ONE 1.0
#define HALF 0.5


/*
 * Fortran to C macros 
 * GPU-friendly array deffinition 
 * i:VL_GLO, j:NVAR 
 *
 */
#define conc(i,j)    conc[(j)*VL_GLO+(i)]
#define khet_st(i,j) khet_st[(j)*VL_GLO+(i)]
#define khet_tr(i,j) khet_tr[(j)*VL_GLO+(i)]
#define jx(i,j)      jx[j*VL_GLO+i]
#define istatus(i,j) istatus[(j)*(VL_GLO)+(i)]   
#define rstatus(i,j) rstatus[(j)*(VL_GLO)+(i)]
#define rconst(i,j)  rconst[(j)*(VL_GLO)+(i)]


/* Temporary arrays allocated in stack */
#define var(i,j)     var[(j)]
#define fix(i,j)     fix[(j)]
#define jcb(i,j)     jcb[(j)]
#define varDot(i,j)  varDot[j]
#define varNew(i,j) varNew[(j)]
#define Fcn0(i,j)   Fcn0[(j)]
#define Fcn(i,j)    Fcn[(j)]
#define Fcn(i,j)    Fcn[(j)]
#define dFdT(i,j)   dFdT[(j)]
#define varErr(i,j) varErr[(j)]
#define K(i,j,k) K[(j)*(NVAR)+(k)]
#define jac0(i,j)    jac0[(j)]    
#define Ghimj(i,j)   Ghimj[(j)]   
#define pivot(i,j)  pivot[(j)*(VL_GLO)+(i)]


/* Enable debug flags for GPU */
//#define DEBUG

#ifdef DEBUG
#define GPU_DEBUG()\
    gpuErrchk( cudaPeekAtLastError()   ); \
    gpuErrchk( cudaDeviceSynchronize() ); 

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

static inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

#else 
/* If debug flags are disabled */
#define GPU_DEBUG()
#define gpuErrchk(ans) ans
#endif

/* This runs on CPU */
double machine_eps_flt()
{
    double machEps = 1.0f;

    do
    {
        machEps /= 2.0f;
        // If next epsilon yields 1, then break, because current
        // epsilon is the machine epsilon.
    }
    while ((double)(1.0 + (machEps/2.0)) != 1.0);

    return machEps;
}

/* This runs on GPU */
__device__ double machine_eps_flt_cuda() 
{
    typedef union 
    {
        long  i64;
        double f64;
    } flt_64;

    flt_64 s;

    s.f64 = 1.;
    s.i64++;
    return (s.f64 - 1.);
}

__device__ double ros_ErrorNorm(double *var, double * __restrict__ varNew, double * __restrict__ varErr, 
                                const double * __restrict__ absTol, const double * __restrict__ relTol,
                                int vectorTol )
{
    double err, scale, varMax;


    err = ZERO;

    if (vectorTol){
        for (int i=0; i<NVAR; i++)
        {
            varMax = fmax(fabs(var[i]),fabs(varNew[i]));
            scale = absTol[i]+ relTol[i]*varMax;

            err += pow((double)varErr[i]/scale,2.0);
        }
        err  = sqrt((double) err/NVAR);
    }else{
        for (int i=0; i<NVAR; i++)
        {
            varMax = fmax(fabs(var[i]),fabs(varNew[i]));

            scale = absTol[0]+ relTol[0]*varMax;
            err += pow((double)varErr[i]/scale,2.0);
        }
        err  = sqrt((double) err/NVAR);
    }

    return err;


}

=#=#=#=#=#=#=#=#=#=#=kppSolve=#=#=#=#=#=#=#=#=#=#=

__device__ void ros_Solve(double *Ghimj, double *K, int &Nsol, int istage,  int ros_S)
{
    kppSolve(Ghimj, K, istage, ros_S);
    Nsol++;
}

=#=#=#=#=#=#=#=#=#=#=kppDecomp=#=#=#=#=#=#=#=#=#=#=

__device__ void ros_Decomp(double *Ghimj, int &Ndec, int VL_GLO)
{
    kppDecomp(Ghimj, VL_GLO);
    Ndec++;
}

__device__ const int LU_DIAG[153] =  {
    1,  2,  3,  4,  5,  6,  7,  8, 11, 16, 18, 22, 
    28, 30, 32, 34, 38, 39, 42, 45, 48, 50, 53, 56, 
    59, 62, 65, 68, 71, 73, 75, 78,118,128,142,145, 
    153,156,167,170,178,184,190,193,198,202,210,214, 
    240,251,258,262,265,267,269,271,273,275,277,279, 
    283,285,287,290,293,295,297,299,301,303,307,310, 
    313,317,322,326,329,333,337,341,346,350,354,358, 
    362,366,370,374,380,384,389,396,400,404,412,419, 
    423,428,434,443,451,457,464,476,488,496,504,512, 
    521,545,558,565,573,580,594,600,612,617,623,629, 
    633,643,655,666,673,685,696,704,713,721,738,752, 
    774,794,828,853,875,901,949,983,1022,1064,1110,1148, 
    1237,1257,1324,1359,1387,1410,1436,1489,1490};


=#=#=#=#=#=#=#=#=#=#=ros_PrepareMatrix=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=Jac_sp=#=#=#=#=#=#=#=#=#=#=

=#=#=#=#=#=#=#=#=#=#=Fun=#=#=#=#=#=#=#=#=#=#=


__device__ void ros_FunTimeDerivative(double T, double roundoff, double *var, double *fix, double *rconst, double *dFdT, double *Fcn0, int &Nfun, int VL_GLO)
{
    int index = blockIdx.x*blockDim.x+threadIdx.x;
    const double DELTAMIN = 1.0E-6;
    double delta,one_over_delta;

    delta = sqrt(roundoff)*fmax(DELTAMIN,fabs(T));
    one_over_delta = 1.0/delta;

    Fun(var, fix, rconst, dFdT, Nfun, VL_GLO);

    for (int i=0; i < NVAR; i++){
        dFdT(index,i) = (dFdT(index,i) - Fcn0(index,i)) * one_over_delta;
    }
}


__device__ int ros_Integrator(double * __restrict__ var, double * __restrict__ fix, double Tstart, double Tend, double &T,
        //  Rosenbrock method coefficients
        const int ros_S, const double * ros_M, const double *  ros_E, const double * __restrict__ ros_A, const double *  ros_C, 
        const double *ros_Alpha, const double * ros_Gamma, const double ros_ELO, const int * ros_NewF, 
        //  Integration parameters
        int autonomous, int vectorTol, int Max_no_steps, 
        double roundoff, double Hmin, double Hmax, double Hstart, double &Hexit, 
        double FacMin, double FacMax, double FacRej, double FacSafe, 
        //  Status parameters
        int &Nfun, int &Njac, int &Nstp, int &Nacc, int &Nrej, int &Ndec, int &Nsol, int &Nsng,
        //  cuda global mem buffers              
        double *rconst,  const double * __restrict__ absTol, const double * __restrict__ relTol, double * __restrict__ varNew, double * __restrict__ Fcn0, 
        double * __restrict__ K, double * __restrict__ dFdT, double * __restrict__ jac0, double * __restrict__ Ghimj, double * __restrict__ varErr,
        // VL_GLO
        int VL_GLO)
{
    int index = blockIdx.x*blockDim.x+threadIdx.x;

    double H, Hnew, HC, HG, Fac; // Tau - not used
    double Err; //*varErr;
    int direction;
    int rejectLastH, rejectMoreH;
    const double DELTAMIN = 1.0E-5;

    //   ~~~>  Initial preparations
    T = Tstart;
    Hexit = 0.0;
    H = fmin(Hstart,Hmax);
    if (fabs(H) <= 10.0*roundoff) 
        H = DELTAMIN;

    if (Tend  >=  Tstart)
    {
        direction = + 1;
    }
    else
    {
        direction = - 1;
    }

    rejectLastH=0;
    rejectMoreH=0;



    //   ~~~> Time loop begins below

    // TimeLoop: 
    while((direction > 0) && ((T- Tend)+ roundoff <= ZERO) || (direction < 0) && ((Tend-T)+ roundoff <= ZERO))
    {
        if (Nstp > Max_no_steps) //  Too many steps
            return -6;
        //  Step size too small
        if (H <= roundoff){  //  Step size too small
            //if (((T+ 0.1*H) == T) || (H <= roundoff)) {
            return -7;
        }

        //   ~~~>  Limit H if necessary to avoid going beyond Tend
        Hexit = H;
        H = fmin(H,fabs(Tend-T));

        //   ~~~>   Compute the function at current time
        Fun(var, fix, rconst, Fcn0, Nfun, VL_GLO);	/// VAR READ - Fcn0 Write

        //   ~~~>  Compute the function derivative with respect to T
        if (!autonomous)
            ros_FunTimeDerivative(T, roundoff, var, fix, rconst, dFdT, Fcn0, Nfun, VL_GLO); /// VAR READ - fcn0 read

        //   ~~~>   Compute the Jacobian at current time
        Jac_sp(var, fix, rconst, jac0, Njac, VL_GLO);   /// VAR READ 

        //   ~~~>  Repeat step calculation until current step accepted
        // UntilAccepted: 
        while(1)
        {
            ros_PrepareMatrix(H, direction, ros_Gamma[0], jac0, Ghimj, Nsng, Ndec, VL_GLO);


            //   ~~~>   Compute the stages
            // Stage: 
            for (int istage=0; istage < ros_S; istage++)
            {
                //   For the 1st istage the function has been computed previously
                if (istage == 0)
                {
                    for (int i=0; i<NVAR; i++){
                        varNew(index,i) = Fcn0(index,i);				// FCN0 Read
                    }
                }
                else if(ros_NewF[istage])
                {
                    for (int j=0; j < (istage); j++){
                        for (int i=0; i<NVAR; i++){		
                            varNew(index,i) = K(index,j,i)*ros_A[(istage)*(istage-1)/2 + j] + var(index,i);
                        }
                    }
                    Fun(varNew, fix, rconst, varNew, Nfun,VL_GLO); // FCN <- varNew / not overlap 
		} 

		for (int i=0; i<NVAR; i++)		
			K(index,istage,i)  = varNew(index,i);

		for (int j=0; j<(istage); j++)
		{
			HC = ros_C[(istage)*(istage-1)/2 + j]/(direction*H);
			for (int i=0; i<NVAR; i++){
				double tmp = K(index,j,i);
				K(index,istage,i) += tmp*HC;
			}
		}

                if ((!autonomous) && (ros_Gamma[istage] ))
                {
                    HG = direction*H*ros_Gamma[istage];
                    for (int i=0; i<NVAR; i++){
                        K(index,istage,i) += dFdT(index,i)*HG;
		     }
                }
		//	   R   ,RW, RW,  R,        R 
                ros_Solve(Ghimj, K, Nsol, istage, ros_S);


            } // Stage

            //  ~~~>  Compute the new solution
	    for (int i=0; i<NVAR; i++){
		    double tmpNew  = var(index,i); 					/// VAR READ
		    double tmpErr  = ZERO;

		    for (int j=0; j<ros_S; j++){
		    	    double tmp = K(index,j,i);
			    if (isnan(tmp)){
			    	printf("Solver detected NAN!");
			    	tmp = 0;
			    }
			    tmpNew += tmp*ros_M[j];
			    tmpErr += tmp*ros_E[j];
		    }
		    varNew(index,i) = tmpNew;			// varNew is killed
		    varErr(index,i) = tmpErr;
	    }

            Err = ros_ErrorNorm(var, varNew, varErr, absTol, relTol, vectorTol);   /// VAR-varNew READ


//  ~~~> New step size is bounded by FacMin <= Hnew/H <= FacMax
            Fac  = fmin(FacMax,fmax(FacMin,FacSafe/pow(Err,ONE/ros_ELO)));
            Hnew = H*Fac;

//  ~~~>  Check the error magnitude and adjust step size
            Nstp = Nstp+ 1;
            if((Err <= ONE) || (H <= Hmin)) // ~~~> Accept step
            {
                Nacc = Nacc + 1;
                for (int j=0; j<NVAR ; j++)
                    var(index,j) =  fmax(varNew(index,j),ZERO);  /////////// VAR WRITE - last VarNew read

                T = T +  direction*H;
                Hnew = fmax(Hmin,fmin(Hnew,Hmax));
                if (rejectLastH)   // No step size increase after a rejected step
                    Hnew = fmin(Hnew,H);
                rejectLastH = 0;
                rejectMoreH = 0;
                H = Hnew;

            	break;  //  EXIT THE LOOP: WHILE STEP NOT ACCEPTED
            }
            else      // ~~~> Reject step
            {
                if (rejectMoreH)
                    Hnew = H*FacRej;
                rejectMoreH = rejectLastH;
                rejectLastH = 1;
                H = Hnew;
                if (Nacc >= 1)
                    Nrej += 1;
            } //  Err <= 1
        } // UntilAccepted
    } // TimeLoop
//  ~~~> Succesful exit
    return 0; //  ~~~> The integration was successful
}

typedef struct {
 double ros_A[15];
 double ros_C[15];
 int   ros_NewF[8];
 double ros_M[6];
 double ros_E[6];
 double ros_Alpha[6];
 double ros_Gamma[6];
 double ros_ELO;
 int    ros_S;
} ros_t;

/*
 * Lookup tables for different ROS for branch elimination. It is much faster in GPU.
 */
__device__ const  ros_t ros[5] = {
    {       
        {.58578643762690495119831127579030,0,0,0,0,0,0,0,0,0,0,0,0,0,0}, /* ros_A */
        {-1.17157287525380990239662255158060,0,0,0,0,0,0,0,0,0,0,0,0,0,0}, /* ros_C */
        {1,1,0,0,0,0,0,0}, /* ros_NewF */
        {.87867965644035742679746691368545,.29289321881345247559915563789515,0,0,0,0}, /* ros_M */
        {.29289321881345247559915563789515,.29289321881345247559915563789515,0,0,0,0}, /* ros_E */
        {0,1.0,0,0,0,0}, /* ros_Alpha */
        {1.70710678118654752440084436210485,-1.70710678118654752440084436210485,0,0,0,0},  /* ros_Gamma */
        2.0, /* ros_ELO */
        2, /* ros_S*/
    }, /* Ros2 */
    {       
        {1.0,1.0,0,0,0,0,0,0,0,0,0,0,0,0,0}, /* ros_A */
        {-0.10156171083877702091975600115545E+01, 0.40759956452537699824805835358067E+01,0.92076794298330791242156818474003E+01,0,0,0,0,0,0,0,0,0,0,0,0}, /* ros_C */
        {1,1,0,0,0,0,0,0}, /* ros_NewF */
        {0.1E+01,0.61697947043828245592553615689730E+01,-0.42772256543218573326238373806514E+00,0,0,0}, /* ros_M */
        {0.5E+00,- 0.29079558716805469821718236208017E+01,0.22354069897811569627360909276199E+00,0,0,0}, /* ros_E */
        {0.0E+00,0.43586652150845899941601945119356E+00,0.43586652150845899941601945119356E+00,0,0,0}, /* ros_Alpha */
        {0.43586652150845899941601945119356E+00,0.24291996454816804366592249683314E+00,0.21851380027664058511513169485832E+01,0,0,0},  /* ros_Gamma */
        3.0, /* ros_ELO */
        3
    }, /* Ros3 */
    {       
        {0.2000000000000000E+01, 0.1867943637803922E+01, 0.2344449711399156E+00, 0.1867943637803922E+01, 0.2344449711399156E+00,0,0,0,0,0,0,0,0,0,0}, /* ros_A */
        {-0.7137615036412310E+01,0.2580708087951457E+01,0.6515950076447975E+00, - 0.2137148994382534E+01, - 0.3214669691237626E+00, - 0.6949742501781779E+00 ,0,0,0,0,0,0,0,0,0}, /* ros_C */
        {1,1,1,0,0,0,0,0}, /* ros_NewF */
        {0.2255570073418735E+01, 0.2870493262186792E+00, 0.4353179431840180E+00, 0.1093502252409163E+01,0,0}, /* ros_M */
        { -0.2815431932141155E+00, -0.7276199124938920E-01, -0.1082196201495311E+00, -0.1093502252409163E+01, 0, 0}, /* ros_E */
        {0.0, 0.1145640000000000E+01, 0.6552168638155900E+00, 0.6552168638155900E+00,0,0}, /* ros_Alpha */
        { 0.5728200000000000E+00, -0.1769193891319233E+01, 0.7592633437920482E+00, -0.1049021087100450E+00,0,0},  /* ros_Gamma */
        4.0, /* ros_ELO */
        4
    }, /* Ros4 */
    {       
        { 0.0E+00, 2.0E+00, 0.0E+00, 2.0E+00, 0.0E+00, 1.0E+00, 0,0,0,0,0,0,0,0,0}, /* ros_A */
        { 4.0E+00, 1.0E+00, - 1.0E+00,  1.0E+00, - 1.0E+00, - 2.66666666666666666666666666666666, 0,0,0,0,0,0,0,0,0}, /* ros_C */
        {1,0,1,1,0,0,0,0}, /* ros_NewF */
        {2.0,0,1.0,1.0,0,0}, /* ros_M */
        {0,0,0,1.0,0,0}, /* ros_E */
        {0,0,1.0,1.0,0,0}, /* ros_Alpha */
        {0.5,1.5,0,0,0,0},  /* ros_Gamma */
        3.0, /* ros_ELO */
        4
    }, /* Rodas3 */

    { 
        {
            0.1544000000000000E+01,  0.9466785280815826E+00, 0.2557011698983284E+00, 0.3314825187068521E+01,
            0.2896124015972201E+01,  0.9986419139977817E+00, 0.1221224509226641E+01, 0.6019134481288629E+01,
            0.1253708332932087E+02, -0.6878860361058950E+00, 0.1221224509226641E+01, 0.6019134481288629E+01,
            0.1253708332932087E+02, -0.6878860361058950E+00, 1.0E+00},  /* ros_A */ 

        {
            -0.5668800000000000E+01, -0.2430093356833875E+01, -0.2063599157091915E+00, -0.1073529058151375E+00,  
            -0.9594562251023355E+01, -0.2047028614809616E+02,  0.7496443313967647E+01, -0.1024680431464352E+02,  
            -0.3399990352819905E+02,  0.1170890893206160E+02,  0.8083246795921522E+01, -0.7981132988064893E+01,  
            -0.3152159432874371E+02,  0.1631930543123136E+02, -0.6058818238834054E+01}, /* ros_C */
        {1,1,1,1,1,1,0,0}, /* ros_NewF */
        {0.1221224509226641E+01,0.6019134481288629E+01,0.1253708332932087E+02,- 0.6878860361058950E+00,1,1}, /* ros_M */
        {0,0,0,0,0,1.0}, /* ros_E */
        {0.000,  0.386,  0.210,  0.630,  1.000, 1.000}, /* ros_Alpha */
        {0.2500000000000000E+00,  -0.1043000000000000E+00,  0.1035000000000000E+00,  0.3620000000000023E-01, 0, 0},  /* ros_Gamma */
        4.0, /* ros_ELO */
        6
    } /* Rodas4 */



};



__device__ double rconst_local[MAX_VL_GLO*NREACT];


__global__ void Rosenbrock(double *conc, double Tstart, double Tend, double *rstatus, int *istatus,
                // values calculated from icntrl and rcntrl at host
                int autonomous, int vectorTol, int UplimTol, int method, int Max_no_steps,
                double Hmin, double Hmax, double Hstart, double FacMin, double FacMax, double FacRej, double FacSafe, double roundoff,
                //  cuda global mem buffers              
                const double * __restrict__ absTol, const double * __restrict__ relTol,
                // extra
                int VL_GLO, int pe)
{
    int index = blockIdx.x*blockDim.x+threadIdx.x;

    /* Temporary arrays allocated in stack */

    /* 
     *  Optimization NOTE: runs faster on Tesla/Fermi 
     *  when tempallocated on stack instead of heap.
     *  In theory someone can aggregate accesses together,
     *  however due to algorithm, threads access 
     *  different parts of memory, making it harder to
     *  optimize accesses. 
     *
     */
    double varNew_stack[NVAR];
    double var_stack[NVAR];
    double varErr_stack[NVAR];
    double fix_stack[NFIX];
    double Fcn0_stack[NVAR];
    double jac0_stack[LU_NONZERO];
    double dFdT_stack[NVAR];
    double Ghimj_stack[LU_NONZERO*3];
    double K_stack[6*NVAR];


    /* Allocated in Global mem */
    double *rconst = rconst_local;

    /* Allocated in stack */
    double *Ghimj  = Ghimj_stack;
    double *K      = K_stack;
    double *varNew = varNew_stack;
    double *Fcn0   = Fcn0_stack;
    double *dFdT   = dFdT_stack;
    double *jac0   = jac0_stack;
    double *varErr = varErr_stack;
    double *var    = var_stack;
    double *fix    = fix_stack;  

    if (index < VL_GLO)
    {

        int Nfun,Njac,Nstp,Nacc,Nrej,Ndec,Nsol,Nsng;
        double Texit, Hexit;

        Nfun = 0;
        Njac = 0;
        Nstp = 0;
        Nacc = 0;
        Nrej = 0;
        Ndec = 0;
        Nsol = 0;
        Nsng = 0;

        /* FIXME: add check for method */
        const double *ros_A     = &ros[method-1].ros_A[0]; 
        const double *ros_C     = &ros[method-1].ros_C[0];
        const double *ros_M     = &ros[method-1].ros_M[0]; 
        const double *ros_E     = &ros[method-1].ros_E[0];
        const double *ros_Alpha = &ros[method-1].ros_Alpha[0]; 
        const double *ros_Gamma = &ros[method-1].ros_Gamma[0]; 
        const int    *ros_NewF  = &ros[method-1].ros_NewF[0];
        const int     ros_S     =  ros[method-1].ros_S; 
        const double  ros_ELO   =  ros[method-1].ros_ELO; 

        /* Copy data from global memory to temporary array */
        /*
         * Optimization note: if we ever have enough constant
         * memory, we could use it for storing the data.
         * In current architectures if we use constant memory
         * only a few threads will be able to run on the fly.
         *
         */
        for (int i=0; i<NVAR; i++)
            var(index,i) = conc(index,i);

        for (int i=0; i<NFIX; i++)
            fix(index,i) = conc(index,NVAR+i);

        /* 
         * Optimization TODO: create versions of the ros_integrator.
         * Initial experiments show a 15-20% performance gain 
         * using specialized version.
         *
         */
        ros_Integrator(var, fix, Tstart, Tend, Texit,
                //  Rosenbrock method coefficients
                ros_S, ros_M, ros_E, ros_A, ros_C, 
                ros_Alpha, ros_Gamma, ros_ELO, ros_NewF, 
                //  Integration parameters
                autonomous, vectorTol, Max_no_steps, 
                roundoff, Hmin, Hmax, Hstart, Hexit, 
                FacMin, FacMax, FacRej, FacSafe,
                //  Status parameters
                Nfun, Njac, Nstp, Nacc, Nrej, Ndec, Nsol, Nsng,
                //  cuda global mem buffers              
                rconst, absTol, relTol, varNew, Fcn0,  
                K, dFdT, jac0, Ghimj,  varErr, VL_GLO
                );

        for (int i=0; i<NVAR; i++)
            conc(index,i) = var(index,i); 


        /* Statistics */
        istatus(index,ifun) = Nfun;
        istatus(index,ijac) = Njac;
        istatus(index,istp) = Nstp;
        istatus(index,iacc) = Nacc;
        istatus(index,irej) = Nrej;
        istatus(index,idec) = Ndec;
        istatus(index,isol) = Nsol;
        istatus(index,isng) = Nsng;
        // Last T and H
        rstatus(index,itexit) = Texit;
        rstatus(index,ihexit) = Hexit; 
    }
}

__device__ double k_3rd(double temp, double cair, double k0_300K, double n, double kinf_300K, double m, double fc)
    /*
 *    
 * temp        temperature [K]
 * cair        air concentration [molecules/cm3]
 * k0_300K     low pressure limit at 300 K
 * n           exponent for low pressure limit
 * kinf_300K   high pressure limit at 300 K
 * m           exponent for high pressure limit
 * fc          broadening factor (usually fc=0.6)
 * 
 */
{

    double zt_help, k0_T, kinf_T, k_ratio, k_3rd_r;

    zt_help = 300.0/temp;
    k0_T    = k0_300K   *pow(zt_help,n) *cair;
    kinf_T  = kinf_300K *pow(zt_help,m);
    k_ratio = k0_T/kinf_T;
    k_3rd_r   = k0_T/(1.0+ k_ratio)*pow(fc,1.0/(1.0+ pow(log10(k_ratio),2)));
    return k_3rd_r;
}

__device__ double k_3rd_iupac(double temp, double cair, double k0_300K, double n, double kinf_300K, double m, double fc)
/*
 *    
 * temp        temperature [K]
 * cair        air concentration [molecules/cm3]
 * k0_300K     low pressure limit at 300 K
 * n           exponent for low pressure limit
 * kinf_300K   high pressure limit at 300 K
 * m           exponent for high pressure limit
 * fc          broadening factor (e.g. 0.45 or 0.6...)
 * nu          N
 * 
 */
{   
 
    double zt_help, k0_T, kinf_T, k_ratio, nu, k_3rd_iupac_r;
    zt_help = 300.0/temp;
    k0_T    = k0_300K   *pow(zt_help,n) *cair;
    kinf_T  = kinf_300K *pow(zt_help,m);
    k_ratio = k0_T/kinf_T;
    nu      = 0.75- 1.27*log10(fc);
    k_3rd_iupac_r = k0_T/(1.0+ k_ratio)*pow(fc,1.0/(1.0+ pow(log10(k_ratio)/nu,2)));
    return k_3rd_iupac_r;
}


/* Initialize rconst local ? */

/*
 * Optimization TODO: these are  constants.
 * Can we replace in place the values of rconst?
 *
 */
=#=#=#=#=#=#=#=#=#=#=update_rconst=#=#=#=#=#=#=#=#=#=#=

                                                        // no int8 in CUDA :(
__global__ void reduce_istatus_1(int *istatus, int4 *tmp_out_1, int4 *tmp_out_2, int VL_GLO, int *xNacc, int *xNrej)
{
    int index = blockIdx.x*blockDim.x+threadIdx.x;
    int idx_1 = threadIdx.x;
    int global_size = blockDim.x*gridDim.x;
    
    int foo;
    //no int8 in CUDA :(
    int4 accumulator_1 = make_int4(0,0,0,0);
    int4 accumulator_2 = make_int4(0,0,0,0);
    while (index < VL_GLO)
    {
        accumulator_1.x += istatus(index,0);
        accumulator_1.y += istatus(index,1);
        accumulator_1.z += istatus(index,2);
        //some dirty work on the side...
        foo = istatus(index,3);
        xNacc[index] = foo;
        accumulator_1.w += foo;
        foo = istatus(index,4);
        xNrej[index] = foo;
        accumulator_2.x += foo;
        accumulator_2.y += istatus(index,5);
        accumulator_2.z += istatus(index,6);
        accumulator_2.w += istatus(index,7);
        index += global_size;
    }
    //no int8 in CUDA :(
    __shared__ int4 buffer_1[REDUCTION_SIZE_1];
    __shared__ int4 buffer_2[REDUCTION_SIZE_1];
    
    buffer_1[idx_1] = accumulator_1;
    buffer_2[idx_1] = accumulator_2;
    __syncthreads();
    
    int idx_2, active_threads = blockDim.x;
    int4 tmp_1, tmp_2;
    while (active_threads != 1)
    {
        active_threads /= 2;
        if (idx_1 < active_threads)
        {
            idx_2 = idx_1+active_threads;
            
            tmp_1 = buffer_1[idx_1];
            tmp_2 = buffer_1[idx_2];
            
            tmp_1.x += tmp_2.x;
            tmp_1.y += tmp_2.y;
            tmp_1.z += tmp_2.z;
            tmp_1.w += tmp_2.w;
            
            buffer_1[idx_1] = tmp_1;
            
            
            tmp_1 = buffer_2[idx_1];
            tmp_2 = buffer_2[idx_2];
            
            tmp_1.x += tmp_2.x;
            tmp_1.y += tmp_2.y;
            tmp_1.z += tmp_2.z;
            tmp_1.w += tmp_2.w;
            
            buffer_2[idx_1] = tmp_1;
            
        }
        __syncthreads();
    }
    if (idx_1 == 0)
    {
        tmp_out_1[blockIdx.x] = buffer_1[0];
        tmp_out_2[blockIdx.x] = buffer_2[0];
    }
}            

__global__ void reduce_istatus_2(int4 *tmp_out_1, int4 *tmp_out_2, int *out)
{
    int idx_1 = threadIdx.x;
    //no int8 in CUDA :(
    __shared__ int4 buffer_1[REDUCTION_SIZE_2];
    __shared__ int4 buffer_2[REDUCTION_SIZE_2];
    
    buffer_1[idx_1] = tmp_out_1[idx_1];
    buffer_2[idx_1] = tmp_out_2[idx_1]; 
    __syncthreads();
    
    int idx_2, active_threads = blockDim.x;
    int4 tmp_1, tmp_2;
    while (active_threads != 1)
    {
        active_threads /= 2;
        if (idx_1 < active_threads)
        {
            idx_2 = idx_1+active_threads;
            
            tmp_1 = buffer_1[idx_1];
            tmp_2 = buffer_1[idx_2];
            
            tmp_1.x += tmp_2.x;
            tmp_1.y += tmp_2.y;
            tmp_1.z += tmp_2.z;
            tmp_1.w += tmp_2.w;
            
            buffer_1[idx_1] = tmp_1;
            
            
            tmp_1 = buffer_2[idx_1];
            tmp_2 = buffer_2[idx_2];
            
            tmp_1.x += tmp_2.x;
            tmp_1.y += tmp_2.y;
            tmp_1.z += tmp_2.z;
            tmp_1.w += tmp_2.w;
            
            buffer_2[idx_1] = tmp_1;
            
        }
        __syncthreads();
    }
    if (idx_1 == 0)
    {
        tmp_1 = buffer_1[0];
        tmp_2 = buffer_2[0];
        out[0] = tmp_1.x;
        out[1] = tmp_1.y;
        out[2] = tmp_1.z;
        out[3] = tmp_1.w;
        out[4] = tmp_2.x;
        out[5] = tmp_2.y;
        out[6] = tmp_2.z;
        out[7] = tmp_2.w;        
    }
}            

/* Assuming different processes */
enum { TRUE=1, FALSE=0 } ;
double *d_conc, *d_temp, *d_press, *d_cair, *d_khet_st, *d_khet_tr, *d_jx;
double *d_rconst;
int initialized = FALSE;

/* Device pointers pointing to GPU */
double *d_rstatus, *d_absTol, *d_relTol;
int *d_istatus, *d_istatus_rd, *d_xNacc, *d_xNrej;
int4 *d_tmp_out_1, *d_tmp_out_2;

/* Allocate arrays on device for Rosenbrock */
__host__ void init_first_time(int pe, int VL_GLO, int size_khet_st, int size_khet_tr, int size_jx ){

    /* Select the proper GPU CARD */
    int deviceCount, device;
    gpuErrchk( cudaGetDeviceCount(&deviceCount) );
    device = pe % deviceCount;
    gpuErrchk( cudaSetDevice(device) );

    printf("PE[%d]: selected %d of total %d\n",pe,device,deviceCount);
    cudaDeviceSetCacheConfig(cudaFuncCachePreferL1); 

    gpuErrchk( cudaMalloc ((void **) &d_conc   , sizeof(double)*VL_GLO*(NSPEC))        );
    gpuErrchk( cudaMalloc ((void **) &d_temp   , sizeof(double)*VL_GLO)              );
    gpuErrchk( cudaMalloc ((void **) &d_press  , sizeof(double)*VL_GLO)              );
    gpuErrchk( cudaMalloc ((void **) &d_cair   , sizeof(double)*VL_GLO)              );
    gpuErrchk( cudaMalloc ((void **) &d_khet_st, sizeof(double)*VL_GLO*size_khet_st) );
    gpuErrchk( cudaMalloc ((void **) &d_khet_tr, sizeof(double)*VL_GLO*size_khet_tr) );
    gpuErrchk( cudaMalloc ((void **) &d_jx     , sizeof(double)*VL_GLO*size_jx)      );
    gpuErrchk( cudaMalloc ((void **) &d_rconst , sizeof(double)*VL_GLO*NREACT));
   
    gpuErrchk( cudaMalloc ((void **) &d_rstatus    , sizeof(double)*VL_GLO*2)          );
    gpuErrchk( cudaMalloc ((void **) &d_istatus    , sizeof(int)*VL_GLO*8)             );
    gpuErrchk( cudaMalloc ((void **) &d_absTol     , sizeof(double)*NVAR)              );
    gpuErrchk( cudaMalloc ((void **) &d_relTol     , sizeof(double)*NVAR)              );

    /* Allocate arrays on device for reduce_foo */
    gpuErrchk( cudaMalloc ((void **) &d_istatus_rd  , sizeof(int)*8));
    gpuErrchk( cudaMalloc ((void **) &d_tmp_out_1   , sizeof(int4)*64));
    gpuErrchk( cudaMalloc ((void **) &d_tmp_out_2   , sizeof(int4)*64));
    gpuErrchk( cudaMalloc ((void **) &d_xNacc   , sizeof(int)*VL_GLO));
    gpuErrchk( cudaMalloc ((void **) &d_xNrej   , sizeof(int)*VL_GLO));
    

    initialized = TRUE;
}

/*
 * TODO: We should call it in some point..
 */
extern "C" void finalize_cuda(){
    /* Free memory on the device */
    gpuErrchk( cudaFree(d_conc        ) );
    gpuErrchk( cudaFree(d_temp        ) );
    gpuErrchk( cudaFree(d_press       ) );
    gpuErrchk( cudaFree(d_cair        ) );
    gpuErrchk( cudaFree(d_khet_st     ) );
    gpuErrchk( cudaFree(d_khet_tr     ) );
    gpuErrchk( cudaFree(d_jx          ) );
    gpuErrchk( cudaFree(d_rstatus     ) );
    gpuErrchk( cudaFree(d_istatus     ) );
    gpuErrchk( cudaFree(d_absTol      ) );
    gpuErrchk( cudaFree(d_relTol      ) );
    gpuErrchk( cudaFree(d_istatus_rd  ) ); 
    gpuErrchk( cudaFree(d_tmp_out_1   ) ); 
    gpuErrchk( cudaFree(d_tmp_out_2   ) ); 
    gpuErrchk( cudaFree(d_xNacc       ) ); 
    gpuErrchk( cudaFree(d_xNrej       ) ); 
}



extern "C" void kpp_integrate_cuda_( int *pe_p, int *sizes, double *time_step_len_p, double *conc, double *temp, double *press, double *cair, 
                                    double *khet_st, double *khet_tr, double *jx, double *absTol, double *relTol, int *ierr, int *istatus, 
                                    int *xNacc, int *xNrej, double *rndoff, int *icntrl=NULL, double *rcntrl=NULL
				    ) 
/*  // TODO
 *  Parameters:
 *          pe_p: scalar int - processor element
 *        VL_GLO: scalar int - size of the system
 *         NSPEC: scalar int - number of species
 *        NREACT: scalar int - number of reactions
 *          NVAR: scalar int - 
 *
 *  Input data:
 *          conc: 2D array of doubles - size: vl_glo x number of species
 *          temp: 1D array of doubles - size: vl_glo
 *         press: 1D array of doubles - size: vl_glo
 *          cair: 1D array of doubles - size: vl_glo
 *       khet_st: 2D array of doubles - size: vl_glo x number of species
 *       khet_tr: 2D array of doubles - size: vl_glo x number of species 
 *            jx: 2D array of doubles - size: vl_glo x number of species
 *        absTol: 1D array of doubles - size: number of species
 *        relTol: 1D array of doubles - size: number of species
 *     Control:
 *        icntrl: 1D array of ints   - size: 4
 *         sizes: 1D array of ints   - size: 4
 *        rcntrl: 1D array of doubles - size: 7
 * 
 * 
 */
{

    const double DELTAMIN = 1.0E-5;


    
    int VL_GLO       = sizes[0];
    int size_khet_st = sizes[1];
    int size_khet_tr = sizes[2];
    int size_jx      = sizes[3];
    double roundoff  = *rndoff; 
    
    double Tstart,Tend;
    Tstart = ZERO;
    Tend   =  *time_step_len_p;
    int pe = *pe_p;
    
    // variables from rcntrl and icntrl
    int autonomous, vectorTol, UplimTol, method, Max_no_steps;
    double Hmin, Hmax, Hstart, FacMin, FacMax, FacRej, FacSafe;
    
    //int rcntrl_bool = 0, icntrl_bool=0;
    if (rcntrl == NULL)
    {
        rcntrl = new double[7];
        for (int i=0; i < 7; i++)
            rcntrl[i] = 0.0;
    }
    if (icntrl == NULL)
    {
        icntrl = new int[4];
        for (int i=0; i < 4; i++)
            icntrl[i] = 0;
    }

    /* Allocate arrays on device for update_rconst kernel*/        
    if (initialized == FALSE)   init_first_time(pe, VL_GLO, size_khet_st, size_khet_tr, size_jx);

    /* Copy data from host memory to device memory */
    gpuErrchk( cudaMemcpy(d_conc   , conc   	, sizeof(double)*VL_GLO*NSPEC        , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_temp   , temp   	, sizeof(double)*VL_GLO              , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_press  , press  	, sizeof(double)*VL_GLO              , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_cair   , cair   	, sizeof(double)*VL_GLO              , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_khet_st, khet_st	, sizeof(double)*VL_GLO*size_khet_st , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_khet_tr, khet_tr	, sizeof(double)*VL_GLO*size_khet_tr , cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_jx     , jx     	, sizeof(double)*VL_GLO*size_jx      , cudaMemcpyHostToDevice) );

    /* Copy arrays from host memory to device memory for Rosenbrock */    
    gpuErrchk( cudaMemcpy(d_absTol, absTol, sizeof(double)*NVAR, cudaMemcpyHostToDevice) );
    gpuErrchk( cudaMemcpy(d_relTol, relTol, sizeof(double)*NVAR, cudaMemcpyHostToDevice) );


    /* Compute execution configuration for update_rconst */
    int block_size, grid_size;
    
    block_size = BLOCKSIZE;
    grid_size = (VL_GLO + block_size - 1)/block_size;  
    dim3 dimBlock(block_size);
    dim3 dimGrid(grid_size);


    /* Execute the kernel */
    update_rconst<<<dimGrid,dimBlock>>>(d_conc, d_temp, d_press, d_cair, d_khet_st, d_khet_tr, d_jx, VL_GLO); 

    GPU_DEBUG();
 
//  *------------------------------------------------------*
//  |    Default values vs input settings (icntrl, rcntrl) |
//  *------------------------------------------------------*
    int ierr_tmp=0;
    {
    //  autonomous or time dependent ODE. Default is time dependent.
        autonomous = !(icntrl[0] == 0);

    //  For Scalar tolerances (icntrl[1].NE.0)  the code uses absTol(0) and relTol(0)
    //  For Vector tolerances (icntrl[1] == 0) the code uses absTol(0:NVAR) and relTol(0:NVAR)
        if (icntrl[1] == 0)
        {
            vectorTol = 1; //bool
            UplimTol  = NVAR;
        }
        else
        {
            vectorTol = 0;
            UplimTol  = 1;
        }

    //  The particular Rosenbrock method chosen
        if (icntrl[2] == 0) 
        {
            method = 4;
        }
        else if ((icntrl[2] >= 1) && (icntrl[2] <= 5))
        {
            method = icntrl[2];
        }
        else
        {
            printf("User-selected Rosenbrock method: icntrl[2]=%d\n",method);
            ierr_tmp = -2;
        }
    //  The maximum number of steps admitted
        if (icntrl[3] == 0)
        {
            Max_no_steps = 100000;
        }
        else if (icntrl[3] > 0) 
        {
            Max_no_steps=icntrl[3];
        }
        else
        {
            printf("User-selected max no. of steps: icntrl[3]=%d\n",icntrl[3]);
            ierr_tmp = -1;
        }
    //  Unit roundoff (1+ roundoff>1)
        roundoff = machine_eps_flt(); 

    //  Lower bound on the step size: (positive value)
        if (rcntrl[0] == ZERO)
        {
            Hmin = ZERO;
        }
        else if (rcntrl[0] > ZERO) 
        {
            Hmin = rcntrl[0];
        }
        else
        {
            printf("User-selected Hmin: rcntrl[0]=%f\n",rcntrl[0]);
            ierr_tmp = -3;
        }
    //  Upper bound on the step size: (positive value)
        if (rcntrl[1] == ZERO) 
        {
            Hmax = fabs(Tend-Tstart);
        }
        else if (rcntrl[1] > ZERO) 
        {
            Hmax = fmin(fabs(rcntrl[1]),fabs(Tend-Tstart));
        }
        else
        {
            printf("User-selected Hmax: rcntrl[1]=%f\n",rcntrl[1]);
            ierr_tmp = -3;
        }
    //  Starting step size: (positive value)
        if (rcntrl[2] == ZERO) 
        {
            Hstart = fmax(Hmin,DELTAMIN);
        }
        else if (rcntrl[2] > ZERO) 
        {
            Hstart = fmin(fabs(rcntrl[2]),fabs(Tend-Tstart));
        }
        else
        {
            printf("User-selected Hstart: rcntrl[2]=%f\n",rcntrl[2]);
            ierr_tmp = -3;
        }
    //  Step size can be changed s.t.  FacMin < Hnew/Hexit < FacMax
        if (rcntrl[3] == ZERO)
        {
            FacMin = 0.2;
        }
        else if (rcntrl[3] > ZERO) 
        {
            FacMin = rcntrl[3];
        }
        else
        {
            printf("User-selected FacMin: rcntrl[3]=%f\n",rcntrl[3]);
            ierr_tmp = -4;
        }
        if (rcntrl[4] == ZERO) 
        {
            FacMax = 6.0;
        }
        else if (rcntrl[4] > ZERO) 
        {
            FacMax = rcntrl[4];
        }
        else
        {
            printf("User-selected FacMax: rcntrl[4]=%f\n",rcntrl[4]);
            ierr_tmp = -4; 
        }
    //  FacRej: Factor to decrease step after 2 succesive rejections
        if (rcntrl[5] == ZERO) 
        {
            FacRej = 0.1;
        }
        else if (rcntrl[5] > ZERO) 
        {
            FacRej = rcntrl[5];
        }
        else
        {
            printf("User-selected FacRej: rcntrl[5]=%f\n",rcntrl[5]);
            ierr_tmp = -4;
        }
    //  FacSafe: Safety Factor in the computation of new step size
        if (rcntrl[6] == ZERO) 
        {
            FacSafe = 0.9;
        }
        else if (rcntrl[6] > ZERO)
        {
            FacSafe = rcntrl[6];
        }
        else
        {
            printf("User-selected FacSafe: rcntrl[6]=%f\n",rcntrl[6]);
            ierr_tmp = -4;
        }
    //  Check if tolerances are reasonable
        for (int i=0; i < UplimTol; i++)
        {
            if ((absTol[i] <= ZERO) || (relTol[i] <= 10.0*roundoff) || (relTol[i] >= 1.0))
            {
                printf("CCC absTol(%d) = %f \n",i,absTol[i]);
                printf("CCC relTol(%d) = %f \n",i,relTol[i]);
                ierr_tmp = -5;
            }
        }
    }

    Rosenbrock<<<dimGrid,dimBlock>>>(d_conc, Tstart, Tend, d_rstatus, d_istatus,
                                     // values calculated from icntrl and rcntrl at host
                                     autonomous, vectorTol, UplimTol, method, Max_no_steps,
                                     Hmin, Hmax, Hstart, FacMin, FacMax, FacRej, FacSafe, roundoff,
                                     //  cuda global mem buffers              
                                     d_absTol, d_relTol,   
                                     // extra - vector lenght and processor
                                     VL_GLO, pe);

    GPU_DEBUG();





    
    reduce_istatus_1<<<REDUCTION_SIZE_2,REDUCTION_SIZE_1>>>(d_istatus, d_tmp_out_1, d_tmp_out_2, VL_GLO, d_xNacc, d_xNrej);


    GPU_DEBUG();

    reduce_istatus_2<<<1,REDUCTION_SIZE_2>>>(d_tmp_out_1, d_tmp_out_2, d_istatus_rd);

    GPU_DEBUG();
    
    /* Copy the result back */
    gpuErrchk( cudaMemcpy( conc      , d_conc       , sizeof(double)*VL_GLO*NVAR, cudaMemcpyDeviceToHost) );  
    gpuErrchk( cudaMemcpy( xNacc      , d_xNacc      , sizeof(int)*VL_GLO         , cudaMemcpyDeviceToHost) );  
    gpuErrchk( cudaMemcpy( xNrej      , d_xNrej      , sizeof(int)*VL_GLO         , cudaMemcpyDeviceToHost) ); 

    
    return;

}




